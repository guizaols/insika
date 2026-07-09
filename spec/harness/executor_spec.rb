# frozen_string_literal: true

require "spec_helper"
require "async/condition"

RSpec.describe Harness::Executor do
  subject(:executor) do
    described_class.new(
      context_builder: inert, policy_engine: inert, middleware: inert, hooks: inert,
      tool_registry: inert, skill_catalog: inert, profiles: {},
      session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:inert) { Object.new } # colaboradores das etapas D/E: inertes no esqueleto
  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream) { Harness::EventStream.new }

  def create_task(id: "t")
    task_store.create(
      command: { type: "send_message", payload: {}, meta: {} },
      session_id: "s", id: id
    )
  end

  # Referência ao actor vivo (introspecção branca — aceitável no esqueleto).
  def live_actor(id) = executor.instance_variable_get(:@running)[id]

  describe "lifecycle feliz (run_pipeline stub)" do
    it "abre Execution attempt 1, passa por :running e emite :task_started seq 1" do
      allow(executor).to receive(:run_pipeline)
      task = create_task
      collected = []

      Sync do |parent|
        sub = event_stream.subscribe(task_id: "t")
        consumer = parent.async { sub.each { |e| collected << e } }
        executor.spawn(task, profile: nil)
        live_actor("t")&.wait
        sub.close
        consumer.wait
      end

      stored = task_store.find("t")
      expect(stored.status).to eq(:running)
      expect(stored.executions.map(&:attempt)).to eq([1])
      started = collected.find { |e| e.type == :task_started }
      expect(started).not_to be_nil
      expect(started.meta[:seq]).to eq(1)
      expect(started.data[:command]).to eq("send_message")
    end
  end

  describe "running? durante e após" do
    it "true enquanto o fiber está suspenso, false após terminar" do
      gate = Async::Condition.new
      allow(executor).to receive(:run_pipeline) { gate.wait }
      task = create_task

      Sync do
        executor.spawn(task, profile: nil)
        expect(executor.running?("t")).to be(true)
        actor = live_actor("t")
        gate.signal
        actor.wait
        expect(executor.running?("t")).to be(false)
      end
    end
  end

  describe "cancelamento cooperativo" do
    it "drain no pipeline após :cancel -> :cancelled + :task_cancelled" do
      gate = Async::Condition.new
      allow(executor).to receive(:run_pipeline) do |_task, _profile, actor, _rf|
        gate.wait
        actor.drain!
      end
      task = create_task
      collected = []

      Sync do |parent|
        sub = event_stream.subscribe(task_id: "t")
        consumer = parent.async { sub.each { |e| collected << e } }
        executor.spawn(task, profile: nil)
        actor = live_actor("t")
        executor.cancel("t") # posta :cancel enquanto o pipeline espera
        gate.signal
        actor.wait
        sub.close
        consumer.wait
      end

      stored = task_store.find("t")
      expect(stored.status).to eq(:cancelled)
      expect(stored.executions.last.outcome).to eq("cancelled")
      expect(stored.executions.last.finished_at).not_to be_nil
      expect(collected.map(&:type)).to include(:task_cancelled)
    end
  end

  describe "cancel sem fiber vivo" do
    it "retorna false e nada emite" do
      expect(executor.cancel("ghost")).to be(false)
    end
  end

  describe "erro genérico no pipeline" do
    it "task :failed com error class/message, :task_failed emitido, fiber não vaza" do
      allow(executor).to receive(:run_pipeline).and_raise(RuntimeError.new("boom"))
      task = create_task
      collected = []

      Sync do |parent|
        sub = event_stream.subscribe(task_id: "t")
        consumer = parent.async { sub.each { |e| collected << e } }
        expect { executor.spawn(task, profile: nil); live_actor("t")&.wait }.not_to raise_error
        sub.close
        consumer.wait
      end

      stored = task_store.find("t")
      expect(stored.status).to eq(:failed)
      expect(stored.executions.last.error).to include("class" => "RuntimeError", "message" => "boom")
      failed = collected.find { |e| e.type == :task_failed }
      expect(failed.data).to include(error: "RuntimeError", message: "boom")
      expect(executor.running?("t")).to be(false) # desregistro no ensure
    end
  end

  describe "spawn duplicado" do
    it "levanta ValidationError se a task já está em execução" do
      gate = Async::Condition.new
      allow(executor).to receive(:run_pipeline) { gate.wait }
      task = create_task

      Sync do
        executor.spawn(task, profile: nil)
        expect { executor.spawn(task, profile: nil) }.to raise_error(Harness::ValidationError)
        actor = live_actor("t")
        gate.signal
        actor.wait
      end
    end
  end

  describe "seq monotônico por task" do
    it "cada emit incrementa meta.seq (task_started + 3 do pipeline = 1..4)" do
      allow(executor).to receive(:run_pipeline) do |task, _p, _a, _r|
        3.times { executor.send(:emit, :content, {}, task: task) }
      end
      task = create_task
      seqs = []

      Sync do |parent|
        sub = event_stream.subscribe(task_id: "t")
        consumer = parent.async { sub.each { |e| seqs << e.meta[:seq] } }
        executor.spawn(task, profile: nil)
        live_actor("t")&.wait
        sub.close
        consumer.wait
      end

      expect(seqs).to eq([1, 2, 3, 4])
      expect(seqs).to eq(seqs.sort) # estritamente crescente
    end
  end

  describe "CancelTask e2e de controle (handler da task 9 + executor real)" do
    it "posta cancel e a task termina :cancelled" do
      gate = Async::Condition.new
      allow(executor).to receive(:run_pipeline) do |_task, _p, actor, _r|
        gate.wait
        actor.drain!
      end
      task = create_task
      handler = Harness::Commands::CancelTask.new(task_store: task_store, executor: executor)

      Sync do
        executor.spawn(task, profile: nil)
        actor = live_actor("t")
        result = handler.call(Harness::Command.build(:cancel_task, { task_id: "t" }))
        expect(result).to be_a(Harness::TaskStore::Task) # síncrono, estado corrente
        gate.signal
        actor.wait
      end

      expect(task_store.find("t").status).to eq(:cancelled)
    end
  end
end
