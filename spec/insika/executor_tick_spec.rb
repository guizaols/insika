# frozen_string_literal: true

require "spec_helper"
require "async"

# the tick's home is the turn supervisor: it starts when the serving
# supervisor is (re)created, binds to the serving reactor in every arm with no
# arm edits, and dies with the supervisor at shutdown.
RSpec.describe "Insika::Executor + the tick" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }

  class FakeTick
    attr_reader :started_with

    def start(parent:)
      @started_with = parent
      true
    end
  end

  def build_executor
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([]), hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  # A Sync block never returns while the supervisor lives (the same teardown
  # the queue/serialization specs use).
  def stop_serving(executor)
    executor.instance_variable_get(:@supervisor)&.stop
  end

  it "serving mode starts the tick as a child of the turn supervisor" do
    executor = build_executor
    executor.supervised = true
    executor.tick = (tick = FakeTick.new)

    Sync do
      supervisor = executor.send(:turn_parent)
      expect(tick.started_with).to be(supervisor)
      stop_serving(executor)
    end
  end

  it "a recreated supervisor restarts the tick (the old one died with its parent)" do
    executor = build_executor
    executor.supervised = true
    executor.tick = (tick = FakeTick.new)

    Sync do
      first = executor.send(:turn_parent)
      stop_serving(executor)
      second = executor.send(:turn_parent)

      expect(second).not_to be(first)
      expect(tick.started_with).to be(second)
      stop_serving(executor)
    end
  end

  it "non-serving mode never touches the tick (boot/recovery stays tick-free)" do
    executor = build_executor # @supervised defaults to false
    executor.tick = (tick = FakeTick.new)

    Sync do
      executor.send(:turn_parent)
      expect(tick.started_with).to be_nil
    end
  end

  it "no tick wired -> serving works exactly as before (parity)" do
    executor = build_executor
    executor.supervised = true

    Sync do
      expect(executor.send(:turn_parent)).to be_a(Async::Task)
      stop_serving(executor)
    end
  end

  # start_supervisor! is what a deployment with only scheduled agents (no live
  # chat) needs: without it, the tick stays silent until unrelated traffic
  # happens to hit turn_parent first — observed live as 16+ minutes of nothing
  # firing after a clean boot.
  describe "#start_supervisor!" do
    it "starts the tick eagerly, before any turn is served" do
      executor = build_executor
      executor.supervised = true
      executor.tick = (tick = FakeTick.new)

      Sync do
        executor.start_supervisor!
        expect(tick.started_with).to be_a(Async::Task)
        stop_serving(executor)
      end
    end

    it "is a no-op outside a reactor (nothing to bind to yet)" do
      executor = build_executor
      executor.supervised = true
      executor.tick = (tick = FakeTick.new)

      executor.start_supervisor!

      expect(tick.started_with).to be_nil
    end

    it "is a no-op when not serving (boot/recovery stays tick-free)" do
      executor = build_executor # @supervised defaults to false
      executor.tick = (tick = FakeTick.new)

      Sync do
        executor.start_supervisor!
        expect(tick.started_with).to be_nil
      end
    end
  end
end
