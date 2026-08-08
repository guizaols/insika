# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/condition"

# RFC-0016 A3 — shutdown is a drain, not a kill. Three properties under test:
# the drain WAITS for in-flight turns and abandons only what outlives the
# deadline; a draining executor closes the TURN intake (tasks stay :queued for
# the next boot's recovery) without gating subagent spawns; and the signal path
# (trap -> pipe -> watcher) delivers exactly one drain and honors the "second
# signal means now" escape hatch.
RSpec.describe Insika::Shutdown do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  # Context builder that blocks at stage 2 until `gate.signal` — the same shape
  # the pause/interrupt specs use to hold a turn in flight deterministically.
  class ShutdownGatingContextBuilder
    def initialize(gate)
      @gate = gate
      @inner = FakeContextBuilder.new
    end

    def call(request)
      @gate.wait
      @inner.call(request)
    end
  end

  def build_executor(context_builder: FakeContextBuilder.new)
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([]), hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  def make_task(id: "t", session: "s1")
    session_store.create(id: session) unless session_store.find(session)
    command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: session, id: id)
  end

  def shutdown_for(executor, timeout:, interrupt: -> {})
    described_class.new(executor: executor, timeout: timeout, logger: nil, interrupt: interrupt)
  end

  # The supervisor + session loops are long-lived; a Sync block will not return
  # while they are alive (same teardown as the queue specs).
  def stop_serving(executor)
    executor.stop_session_actors
    executor.instance_variable_get(:@supervisor)&.stop
  end

  describe "#drain" do
    it "waits for the in-flight turn and reports a clean drain" do
      gate = Async::Condition.new
      executor = build_executor(context_builder: ShutdownGatingContextBuilder.new(gate))
      allow(executor).to receive(:create_chat).and_return(FakeChat.new)

      Sync do |top|
        executor.spawn(make_task, profile: profile) # blocked at the stage-2 gate
        drainer = top.async { shutdown_for(executor, timeout: 2).drain }
        top.sleep(0.02)
        expect(executor.draining?).to be true

        gate.signal # the turn finishes while the drain is waiting
        result = drainer.wait
        expect(result).to eq(drained: true, abandoned: [])
        expect(task_store.find("t").status).to eq(:completed)
      end
    end

    it "abandons what outlives the deadline — :running, for the next boot's recovery" do
      gate = Async::Condition.new
      executor = build_executor(context_builder: ShutdownGatingContextBuilder.new(gate))
      allow(executor).to receive(:create_chat).and_return(FakeChat.new)

      Sync do |top|
        executor.spawn(make_task, profile: profile) # blocked; never released in time
        result = top.async { shutdown_for(executor, timeout: 0.15).drain }.wait
        expect(result).to eq(drained: false, abandoned: ["t"])
        # Abandoned means UNTOUCHED: the task stays :running (the orphan shape
        # Recovery's sweep looks for), never :failed/:cancelled by the drain.
        expect(task_store.find("t").status).to eq(:running)

        gate.signal # unwind: let the fiber finish so Sync can return
        executor.instance_variable_get(:@running)["t"]&.wait
        expect(task_store.find("t").status).to eq(:completed)
      end
    end
  end

  describe "a draining executor (the intake)" do
    it "leaves a new turn :queued, answers its id, and emits :turn_deferred" do
      executor = build_executor
      executor.supervised = true
      executor.begin_drain!

      Sync do
        task = make_task
        expect(executor.spawn_in_session(task, profile: profile)).to eq("t")
        expect(task_store.find("t").status).to eq(:queued) # recovery replays :queued
        expect(executor.running?("t")).to be false
        expect(event_stream.types).to include(:turn_deferred)
        stop_serving(executor)
      end
    end

    it "defers the turns queued behind the one being drained (the loop stops feeding)" do
      gate = Async::Condition.new
      executor = build_executor(context_builder: ShutdownGatingContextBuilder.new(gate))
      executor.supervised = true
      allow(executor).to receive(:create_chat).and_return(FakeChat.new)

      Sync do |top|
        executor.spawn_in_session(make_task(id: "t1"), profile: profile)
        executor.spawn_in_session(make_task(id: "t2"), profile: profile)
        top.sleep(0.02) # t1 in flight (gated), t2 queued behind it

        executor.begin_drain!
        gate.signal # t1 finishes; the loop dequeues t2 and must NOT spawn it
        top.sleep(0.05)
        expect(task_store.find("t1").status).to eq(:completed)
        expect(task_store.find("t2").status).to eq(:queued)
        expect(executor.in_flight).to be_empty
        stop_serving(executor)
      end
    end

    it "does NOT gate a direct spawn — a subagent child is part of the work being drained" do
      executor = build_executor
      allow(executor).to receive(:create_chat).and_return(FakeChat.new)
      executor.begin_drain!

      Sync do
        executor.spawn(make_task, profile: profile)
        executor.instance_variable_get(:@running)["t"]&.wait
        expect(task_store.find("t").status).to eq(:completed)
      end
    end
  end

  describe "the signal path" do
    it "first signal wakes the watcher: drain, then exactly one interrupt" do
      executor = build_executor
      interrupts = []
      shutdown = shutdown_for(executor, timeout: 0.1, interrupt: -> { interrupts << :stop })

      shutdown.signal_received # what the trap does: one byte into the pipe
      Thread.new { shutdown.watch }.join(2)

      expect(executor.draining?).to be true
      expect(interrupts).to eq([:stop])
    end

    it "a second signal skips the wait and interrupts immediately" do
      executor = build_executor
      interrupts = []
      shutdown = shutdown_for(executor, timeout: 0.1, interrupt: -> { interrupts << :stop })

      shutdown.signal_received # first: schedules the drain
      shutdown.signal_received # second: the operator insisting means now
      expect(interrupts).to eq([:stop])
    end
  end

  describe ".default_timeout" do
    it "reads INSIKA_DRAIN_TIMEOUT and falls back to the default on absence/garbage" do
      expect(described_class.default_timeout).to eq(described_class::DEFAULT_TIMEOUT)
      begin
        ENV["INSIKA_DRAIN_TIMEOUT"] = "7"
        expect(described_class.default_timeout).to eq(7)
        ENV["INSIKA_DRAIN_TIMEOUT"] = "not-a-number"
        expect(described_class.default_timeout).to eq(described_class::DEFAULT_TIMEOUT)
      ensure
        ENV.delete("INSIKA_DRAIN_TIMEOUT")
      end
    end
  end
end
