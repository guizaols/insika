# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Recovery do
  # REAL stores (tasks 06/07) over Memory + DOUBLE command_bus (doc 02 §7).
  let(:backend) { Harness::Stores::Memory.new }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:bus) { RecordingBus.new }

  subject(:recovery) do
    described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                        command_bus: bus)
  end

  # Minimal double — the real bus integration is task 13.
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

  # Bus that raises only on the first call (contaminates 1 task, not the others).
  class FlakyBus
    attr_reader :dispatched

    def initialize
      @dispatched = []
      @calls = 0
    end

    def dispatch(command)
      @calls += 1
      raise "failure on the 1st dispatch" if @calls == 1

      @dispatched << command
    end
  end

  # task_store whose backend raises StoreError during the sweep (corrupted store).
  class ExplodingTaskStore
    def running_or_interrupted = raise Harness::StoreError, "backend corrompido"
  end

  let(:command) { { type: "send_message", payload: {}, meta: {} } }

  # Creates a task already in the target state (via a valid path) with an open Execution.
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

  describe "running with checkpoint -> resume" do
    it "dispatches resume_task, id in resumed, status stays running" do
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

  describe "waiting/paused with checkpoint -> resume" do
    it "dispatches both and both in resumed" do
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

  describe "running without checkpoint -> failed" do
    it "does not dispatch, marks :failed and closes the Execution with the error" do
      seed_task("t", status: :running)

      result = recovery.run

      expect(bus.dispatched).to be_empty
      expect(result[:failed]).to eq(["t"])
      task = task_store.find("t")
      expect(task.status).to eq(:failed)
      expect(task.executions.last.error).to eq(
        { "class" => "Harness::Error", "message" => "unrecoverable: no checkpoint" }
      )
    end
  end

  describe "empty store -> no-op" do
    it "returns empty without calling the bus" do
      result = recovery.run

      expect(result).to eq({ resumed: [], failed: [] })
      expect(bus.dispatched).to be_empty
    end
  end

  describe "mixed scenario" do
    it "only running-c/-cp resume; without-cp fails; terminals untouched" do
      seed_task("r", status: :running)
      seed_checkpoint("r")
      seed_task("w", status: :waiting) # no checkpoint
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

  describe "failure resuming ONE task does not bring down the boot" do
    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: RecordingBus.new(raise_on: RuntimeError.new("bus caiu")))
    end

    it "does not raise; task goes to :failed with stage recovery; id in failed" do
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

  describe "one failure does not contaminate the others" do
    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: flaky)
    end

    let(:flaky) { FlakyBus.new }

    it "the 2nd is dispatched; summary separates resumed and failed" do
      # sweep is lexicographic: "a" processed before "b"
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

  describe "paused without checkpoint (invalid transition absorbed)" do
    it "does not raise; id in failed; status stays paused" do
      seed_task("p", status: :paused) # no checkpoint

      result = nil
      expect { result = recovery.run }.not_to raise_error
      expect(result[:failed]).to eq(["p"])
      expect(task_store.find("p").status).to eq(:paused) # paused -> failed is invalid
    end
  end

  describe "corrupted store aborts the boot" do
    subject(:recovery) do
      described_class.new(task_store: ExplodingTaskStore.new,
                          checkpoint_store: checkpoint_store, command_bus: bus)
    end

    it "propagates StoreError" do
      expect { recovery.run }.to raise_error(Harness::StoreError)
    end
  end

  describe "shape of the dispatched Command" do
    it "is Harness::Command :resume_task with correct payload and meta" do
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

  describe "logger with a bug does not affect the flow (observability is not control)" do
    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: bus, logger: exploding_logger)
    end

    let(:exploding_logger) do
      Class.new do
        def info(*) = raise "logger caiu"
        def warn(*) = raise "logger caiu"
      end.new
    end

    it "does not raise and does not put the id in resumed AND failed at the same time" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      result = nil
      expect { result = recovery.run }.not_to raise_error
      expect(result[:resumed]).to eq(["t"])
      expect(result[:failed]).to be_empty
    end
  end

  describe "integration with real CommandBus + ResumeTask handler (task 13)" do
    let(:profile) { Harness::AgentProfile.build(id: "a", model: "m") }
    let(:spawn_executor) do
      Class.new do
        attr_reader :spawned

        def initialize = (@spawned = [])
        def running?(_id) = false
        def spawn_in_session(task, profile:, resume_from:) = @spawned << task.id
      end.new
    end

    def real_bus(profiles)
      handler = Harness::Commands::ResumeTask.new(profiles: profiles, task_store: task_store,
                                                  checkpoint_store: checkpoint_store,
                                                  executor: spawn_executor)
      bus = Harness::CommandBus.new
      bus.register(:resume_task, handler)
      bus
    end

    subject(:recovery) do
      described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                          command_bus: real_bus({ "a" => profile }))
    end

    it "routes the Recovery dispatch to the real handler (spawn of the orphan)" do
      seed_task("t", status: :running) # handler's running? is false -> eligible orphan
      seed_checkpoint("t")

      result = recovery.run

      expect(result[:resumed]).to eq(["t"])
      expect(spawn_executor.spawned).to eq(["t"])
    end

    it "re-enqueues :queued task (turn queued at crash, P2-03) — not lost on kill -9" do
      # :queued = created but never started (no checkpoint). Before the fix,
      # running_or_interrupted ignored it and it was lost.
      task_store.create(command: { "type" => "send_message", "payload" => { "agent" => "a" } }, id: "q")

      result = recovery.run

      expect(result[:resumed]).to include("q")
      expect(spawn_executor.spawned).to include("q") # re-run from scratch
    end

    it "isolated failure: removed agent does not bring down the boot (doc 02 §6)" do
      seed_task("ok", status: :running)
      seed_checkpoint("ok") # agent_id "a" -> ok
      seed_task("bad", status: :running)
      checkpoint_store.save(Harness::Checkpoint.new(task_id: "bad", turn: 1, session_id: nil,
                                                    agent_id: "sumiu", messages: [],
                                                    completed_side_effects: [], created_at: nil))
      recovery = described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                                     command_bus: real_bus({ "a" => profile }))

      result = recovery.run

      expect(result[:resumed]).to eq(["ok"])
      expect(result[:failed]).to eq(["bad"])
      expect(task_store.find("bad").status).to eq(:failed)
    end
  end

  describe "summary" do
    it "is exactly { resumed:, failed: }" do
      seed_task("r", status: :running)
      seed_checkpoint("r")
      seed_task("f", status: :running) # no checkpoint

      expect(recovery.run).to eq({ resumed: ["r"], failed: ["f"] })
    end
  end
end
