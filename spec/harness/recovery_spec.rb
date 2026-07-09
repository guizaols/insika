# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Recovery do
  # Stores REAIS (tasks 06/07) sobre Memory + command_bus DUPLO (doc 02 §7).
  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:bus) { RecordingBus.new }

  subject(:recovery) do
    described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                        command_bus: bus)
  end

  # Duplo mínimo — a integração real do bus é a task 13.
  class RecordingBus
    attr_reader :dispatched

    def initialize(raise_on: nil)
      @dispatched = []
      @raise_on = raise_on
    end

    def dispatch(command)
      raise @raise_on if @raise_on

      @dispatched << command
    end
  end

  # Bus que levanta só na primeira chamada (contamina 1 task, não as outras).
  class FlakyBus
    attr_reader :dispatched

    def initialize
      @dispatched = []
      @calls = 0
    end

    def dispatch(command)
      @calls += 1
      raise "falha no 1º dispatch" if @calls == 1

      @dispatched << command
    end
  end

  # task_store cujo backend levanta StoreError na varredura (store corrompido).
  class ExplodingTaskStore
    def running_or_interrupted = raise Harness::StoreError, "backend corrompido"
  end

  let(:command) { { type: "send_message", payload: {}, meta: {} } }

  # Cria uma task já no estado alvo (por caminho válido) com Execution aberta.
  def seed_task(id, status:)
    task_store.create(command: command, id: id)
    task_store.begin_execution(id)
    task_store.transition(id, to: :running)
    task_store.transition(id, to: status) unless status == :running
    id
  end

  def seed_checkpoint(id, turn: 1)
    checkpoint_store.save(
      Harness::Checkpoint.new(
        task_id: id, turn: turn, session_id: "s", agent_id: "a",
        messages: [], completed_side_effects: [], created_at: nil
      )
    )
  end

  describe "running com checkpoint -> resume" do
    it "despacha resume_task, id em resumed, status permanece running" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      result = recovery.run

      expect(bus.dispatched.size).to eq(1)
      expect(bus.dispatched.first.type).to eq(:resume_task)
      expect(bus.dispatched.first.payload).to eq({ task_id: "t" })
      expect(result[:resumed]).to eq(["t"])
      expect(task_store.find("t").status).to eq(:running)
    end
  end

  describe "waiting/paused com checkpoint -> resume" do
    it "despacha ambas e ambas em resumed" do
      seed_task("w", status: :waiting)
      seed_checkpoint("w")
      seed_task("p", status: :paused)
      seed_checkpoint("p")

      result = recovery.run

      expect(bus.dispatched.size).to eq(2)
      expect(result[:resumed]).to contain_exactly("w", "p")
      expect(result[:failed]).to be_empty
    end
  end

  describe "running sem checkpoint -> failed" do
    it "não despacha, marca :failed e fecha a Execution com o erro" do
      seed_task("t", status: :running)

      result = recovery.run

      expect(bus.dispatched).to be_empty
      expect(result[:failed]).to eq(["t"])
      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error).to eq(
        { "class" => "Harness::Error", "message" => "irrecuperável: sem checkpoint" }
      )
    end
  end

  describe "store vazio -> no-op" do
    it "retorna vazio sem chamar o bus" do
      result = recovery.run

      expect(result).to eq({ resumed: [], failed: [] })
      expect(bus.dispatched).to be_empty
    end
  end

  describe "cenário misto" do
    it "só running-c/-cp resume; sem-cp falha; terminais intocadas" do
      seed_task("r", status: :running)
      seed_checkpoint("r")
      seed_task("w", status: :waiting) # sem checkpoint
      done = seed_task("d", status: :running)
      task_store.finish_execution(done, outcome: "completed")
      task_store.transition(done, to: :completed)
      seed_task("c", status: :running)
      task_store.transition("c", to: :cancelled)

      result = recovery.run

      expect(result[:resumed]).to eq(["r"])
      expect(result[:failed]).to eq(["w"])
      expect(task_store.find("d").status).to eq(:completed)
      expect(task_store.find("c").status).to eq(:cancelled)
    end
  end

  describe "falha ao retomar UMA task não derruba o boot" do
    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: RecordingBus.new(raise_on: RuntimeError.new("bus caiu")))
    end

    it "não levanta; task vai a :failed com stage recovery; id em failed" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      result = nil
      expect { result = recovery.run }.not_to raise_error
      expect(result[:failed]).to eq(["t"])
      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error).to include(
        "class" => "RuntimeError", "message" => "bus caiu", "stage" => "recovery"
      )
    end
  end

  describe "falha de uma não contamina as outras" do
    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: flaky)
    end

    let(:flaky) { FlakyBus.new }

    it "a 2ª é despachada; sumário separa resumed e failed" do
      # varredura é lexicográfica: "a" processada antes de "b"
      seed_task("a", status: :running)
      seed_checkpoint("a")
      seed_task("b", status: :running)
      seed_checkpoint("b")

      result = recovery.run

      expect(result[:resumed]).to eq(["b"])
      expect(result[:failed]).to eq(["a"])
      expect(flaky.dispatched.map { |c| c.payload[:task_id] }).to eq(["b"])
    end
  end

  describe "paused sem checkpoint (transição inválida absorvida)" do
    it "não levanta; id em failed; status permanece paused" do
      seed_task("p", status: :paused) # sem checkpoint

      result = nil
      expect { result = recovery.run }.not_to raise_error
      expect(result[:failed]).to eq(["p"])
      expect(task_store.find("p").status).to eq(:paused) # paused -> failed é inválido
    end
  end

  describe "store corrompido aborta o boot" do
    subject(:recovery) do
      described_class.new(task_store: ExplodingTaskStore.new,
                          checkpoint_store: checkpoint_store, command_bus: bus)
    end

    it "propaga StoreError" do
      expect { recovery.run }.to raise_error(Harness::StoreError)
    end
  end

  describe "shape do Command despachado" do
    it "é Harness::Command :resume_task com payload e meta corretos" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      recovery.run
      command = bus.dispatched.first

      expect(command).to be_a(Harness::Command)
      expect(command.type).to eq(:resume_task)
      expect(command.payload).to eq({ task_id: "t" })
      expect(command.meta[:transport]).to eq(:recovery)
      expect(command.meta[:command_id]).to be_a(String)
      expect { Time.iso8601(command.meta[:issued_at]) }.not_to raise_error
    end
  end

  describe "sumário" do
    it "é exatamente { resumed:, failed: }" do
      seed_task("r", status: :running)
      seed_checkpoint("r")
      seed_task("f", status: :running) # sem checkpoint

      expect(recovery.run).to eq({ resumed: ["r"], failed: ["f"] })
    end
  end
end
