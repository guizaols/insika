# frozen_string_literal: true

require "spec_helper"
require "async"
require "async/condition"

# :paused suspension in the Executor (P2 task 2). Pausing requires catching :pause at a
# boundary BEFORE stage 6 — a gated context builder suspends the turn at
# stage 2, allowing :pause to be posted before the boundary that consumes it.
RSpec.describe "Insika::Executor — :paused suspension" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt", base_prompt: "SOUL") }

  # Context builder that blocks at stage 2 until `gate.signal`, then delegates.
  class GatingContextBuilder
    def initialize(gate)
      @gate = gate
      @inner = FakeContextBuilder.new
    end

    def call(request)
      @gate.wait
      @inner.call(request)
    end
  end

  def build_executor(context_builder:)
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  def make_task
    session_store.create(id: "s1")
    command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: "t")
  end

  def actor_of(executor) = executor.instance_variable_get(:@running)["t"]

  it "suspends at :paused on the boundary and resumes on :resume until complete" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do |top|
      executor.spawn(make_task, profile: profile) # runs until the stage 2 gate (suspends)
      actor = actor_of(executor)
      actor.post(:pause)                            # :pause in the mailbox before the boundary
      gate.signal                                   # stage 2 returns -> boundary sees :pause
      top.sleep(0.02)
      expect(task_store.find("t").status).to eq(:paused)
      expect(event_stream.types).to include(:task_paused)

      actor.post(:resume)
      actor.wait
      expect(task_store.find("t").status).to eq(:completed)
      expect(event_stream.types).to include(:task_resumed)
      # order: paused comes before resumed, resumed before the terminal
      types = event_stream.types
      expect(types.index(:task_paused)).to be < types.index(:task_resumed)
      expect(types.index(:task_resumed)).to be < types.index(:task_completed)
    end
  end

  it ":cancel during :paused -> :cancelled (valid transition)" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do |top|
      executor.spawn(make_task, profile: profile)
      actor = actor_of(executor)
      actor.post(:pause)
      gate.signal
      top.sleep(0.02)
      expect(task_store.find("t").status).to eq(:paused)

      actor.post(:cancel) # cancel while paused
      actor.wait
      expect(task_store.find("t").status).to eq(:cancelled)
      expect(event_stream.types).to include(:task_cancelled)
    end
  end

  it "without :pause the flow is identical to Phase 1 (no :task_paused)" do
    gate = Async::Condition.new
    executor = build_executor(context_builder: GatingContextBuilder.new(gate))
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do
      executor.spawn(make_task, profile: profile)
      gate.signal # no pause posted
      actor_of(executor).wait
      expect(task_store.find("t").status).to eq(:completed)
      expect(event_stream.types).not_to include(:task_paused)
    end
  end
end
