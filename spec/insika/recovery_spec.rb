# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::Recovery do
  # REAL stores (tasks 06/07) over Memory + DOUBLE command_bus (doc 02 §7).
  let(:backend) { Insika::Stores::Memory.new }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
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
    def running_or_interrupted = raise Insika::StoreError, "backend corrompido"
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
      Insika::Checkpoint.new(
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
        { "class" => "Insika::Error", "message" => "unrecoverable: no checkpoint" }
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
      expect { recovery.run }.to raise_error(Insika::StoreError)
    end
  end

  describe "shape of the dispatched Command" do
    it "is Insika::Command :resume_task with correct payload and meta" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      recovery.run
      command = bus.dispatched.first

      expect(command).to be_a(Insika::Command)
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
    let(:profile) { Insika::AgentProfile.build(id: "a", model: "m") }
    let(:spawn_executor) do
      Class.new do
        attr_reader :spawned

        def initialize = (@spawned = [])
        def running?(_id) = false
        def spawn_in_session(task, profile:, resume_from:) = @spawned << task.id
      end.new
    end

    def real_bus(profiles)
      handler = Insika::Commands::ResumeTask.new(profiles: profiles, task_store: task_store,
                                                  checkpoint_store: checkpoint_store,
                                                  executor: spawn_executor)
      bus = Insika::CommandBus.new
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
      checkpoint_store.save(Insika::Checkpoint.new(task_id: "bad", turn: 1, session_id: nil,
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

  # RFC-0019: tick mode. Boot's premise ("nothing is alive") is false on a
  # timer, so candidates are only :queued/:running tasks untouched past the
  # threshold, and a ValidationError from the dispatch (ResumeTask's local
  # liveness check) SKIPS the task instead of failing it.
  describe "stale_after: (tick mode)" do
    # updated_at is the liveness signal; specs age a task by rewriting it.
    def backdate(id, seconds)
      key = "task:#{id}"
      record = backend.get("tasks", key)
      record["updated_at"] = (Time.now.utc - seconds).iso8601
      backend.set("tasks", key, record)
    end

    it "resumes a stale :running task with a checkpoint" do
      seed_task("t", status: :running)
      seed_checkpoint("t")
      backdate("t", 1_000)

      result = recovery.run(stale_after: 900)

      expect(result[:resumed]).to eq(["t"])
      expect(bus.dispatched.map { |c| c.payload[:task_id] }).to eq(["t"])
    end

    it "leaves a FRESH :running task completely untouched (not resumed, not failed)" do
      seed_task("t", status: :running)
      seed_checkpoint("t")

      result = recovery.run(stale_after: 900)

      expect(result).to eq({ resumed: [], failed: [] })
      expect(bus.dispatched).to be_empty
      expect(task_store.find("t").status).to eq(:running)
    end

    it "sweeps a stale :queued task but not a fresh one (a live queue drains in seconds)" do
      task_store.create(command: command, id: "old")
      task_store.create(command: command, id: "new")
      backdate("old", 1_000)

      result = recovery.run(stale_after: 900)

      expect(result[:resumed]).to eq(["old"])
      expect(task_store.find("new").status).to eq(:queued)
    end

    it "never touches :waiting/:paused — idle by nature, staleness cannot judge them" do
      seed_task("w", status: :waiting)
      seed_checkpoint("w")
      backdate("w", 10_000)
      seed_task("p", status: :paused)
      seed_checkpoint("p")
      backdate("p", 10_000)

      result = recovery.run(stale_after: 900)

      expect(result).to eq({ resumed: [], failed: [] })
      expect(bus.dispatched).to be_empty
    end

    it "an unreadable updated_at is not proof of life — treated as stale" do
      seed_task("t", status: :running)
      seed_checkpoint("t")
      key = "task:t"
      record = backend.get("tasks", key)
      record["updated_at"] = "not-a-timestamp"
      backend.set("tasks", key, record)

      result = recovery.run(stale_after: 900)

      expect(result[:resumed]).to eq(["t"])
    end

    describe "ValidationError from the dispatch (the E2 trap, defused)" do
      subject(:recovery) do
        described_class.new(task_store: task_store, checkpoint_store: checkpoint_store,
                            command_bus: RecordingBus.new(raise_on: Insika::ValidationError.new("task 't' is running")))
      end

      it "tick mode SKIPS the task: not resumed, not failed, status untouched" do
        seed_task("t", status: :running)
        seed_checkpoint("t")
        backdate("t", 1_000)

        result = nil
        expect { result = recovery.run(stale_after: 900) }.not_to raise_error
        expect(result).to eq({ resumed: [], failed: [] })
        expect(task_store.find("t").status).to eq(:running)
      end

      it "boot mode keeps the old contract: corruption -> :failed" do
        seed_task("t", status: :running)
        seed_checkpoint("t")

        result = recovery.run

        expect(result[:failed]).to eq(["t"])
        expect(task_store.find("t").status).to eq(:failed)
      end
    end
  end

  # RFC-0016 E2: the task sweep runs once per boot generation. The sweep's
  # "orphaned :running" test is per-process, so N workers sweeping at once (or
  # a worker respawned while siblings hold live turns) would double-resume;
  # the claim makes the first worker per boot_id the only sweeper.
  describe ".claim_sweep" do
    it "grants the first claim of a generation and refuses the second" do
      expect(described_class.claim_sweep(store: backend, boot_id: "gen-1")).to be(true)
      expect(described_class.claim_sweep(store: backend, boot_id: "gen-1")).to be(false)
    end

    it "a new generation claims independently of the previous one" do
      described_class.claim_sweep(store: backend, boot_id: "gen-1")

      expect(described_class.claim_sweep(store: backend, boot_id: "gen-2")).to be(true)
    end

    it "blank boot_id -> always true (single-process arms sweep every boot)" do
      expect(described_class.claim_sweep(store: backend, boot_id: nil)).to be(true)
      expect(described_class.claim_sweep(store: backend, boot_id: "")).to be(true)
      expect(described_class.claim_sweep(store: backend, boot_id: nil)).to be(true)
    end

    it "exactly one of two SQLite handles wins the same generation (cross-process claim)" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "claims.db")
        handle_a = Insika::Stores::SQLite.new(path: db_path)
        handle_b = Insika::Stores::SQLite.new(path: db_path)
        barrier = Queue.new
        results = Array.new(2)
        threads = [handle_a, handle_b].each_with_index.map do |handle, i|
          Thread.new do
            barrier.pop
            results[i] = described_class.claim_sweep(store: handle, boot_id: "boot-77")
          end
        end
        2.times { barrier << :go }
        threads.each(&:join)

        expect(results.count(true)).to eq(1), "both workers claimed the sweep: #{results.inspect}"
      ensure
        handle_a&.close
        handle_b&.close
      end
    end
  end
end
