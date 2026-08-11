# frozen_string_literal: true

require "spec_helper"
require "async"

# the `collect` door as the Executor exposes it. Every guard here
# exists so that a wiring which did NOT ask for coalescing gets exactly the
# behavior it had before the feature: a task of its own, per message.
RSpec.describe "Insika::Executor + the collect door" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }

  def profile(limits) = Insika::AgentProfile.build(id: "a", model: "gpt", limits: limits)

  def build_executor(settings_store: nil)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([]), hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      settings_store: settings_store
    )
  end

  def settings(queue) = Struct.new(:get).new({ "queue" => queue })

  let(:collecting) { profile({ queue_mode: "collect", debounce_ms: 50 }) }

# The supervisor is a long-lived task created lazily by the serving arm; a Sync
# block will not return while it is alive (same teardown the session-serialization
# integration spec uses).
def stop_serving(executor)
  executor.stop_session_actors
  executor.instance_variable_get(:@supervisor)&.stop
end

before { session_store.create(id: "s1") }

  it "returns nil when the executor is not serving — at boot/recovery there is no door" do
    executor = build_executor # @supervised defaults to false

    Sync { expect(executor.collect_into_pending("s1", "oi", profile: collecting)).to be_nil }
  end

  it "returns nil for followup, even with a window configured" do
    executor = build_executor
    executor.supervised = true

    Sync do
      expect(executor.collect_into_pending("s1", "oi", profile: profile({ debounce_ms: 50 })))
        .to be_nil
    end
  end

  it "returns nil for collect WITHOUT a window — there is nothing to hold a turn at the door" do
    executor = build_executor
    executor.supervised = true

    Sync do
      expect(executor.collect_into_pending("s1", "oi", profile: profile({ queue_mode: "collect" })))
        .to be_nil
    end
  end

  it "returns nil when the session has no actor yet (the first message of a session)" do
    executor = build_executor
    executor.supervised = true

    Sync { expect(executor.collect_into_pending("s1", "oi", profile: collecting)).to be_nil }
  end

  it "merges into the turn waiting at the door and emits :turn_coalesced when it closes" do
    executor = build_executor
    executor.supervised = true
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)

    Sync do |top|
      command = Insika::Command.build(:send_message, { agent: "a", message: "oi" })
      task = task_store.create(command: command.to_h, session_id: "s1", id: "t1")
      executor.spawn_in_session(task, profile: collecting)
      top.sleep(0.01)

      # The turn is created but held: the fragment joins it instead of spawning.
      expect(executor.collect_into_pending("s1", "queria o pedido", profile: collecting)).to eq("t1")
      expect(task_store.find("t1").command["payload"]["message"]).to eq("oi\nqueria o pedido")

      top.sleep(0.12) # the window closes and the turn runs
      expect(executor.collect_into_pending("s1", "tarde", profile: collecting)).to be_nil
      expect(event_stream.types).to include(:turn_coalesced)
      stop_serving(executor)
    end
  end

  it "the platform default reaches an agent that declares nothing" do
    executor = build_executor(settings_store: settings({ "queue_mode" => "collect",
                                                         "debounce_ms" => 50 }))
    executor.supervised = true
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)
    bare = profile({})

    Sync do |top|
      command = Insika::Command.build(:send_message, { agent: "a", message: "oi" })
      task = task_store.create(command: command.to_h, session_id: "s1", id: "t1")
      executor.spawn_in_session(task, profile: bare)
      top.sleep(0.01)

      expect(executor.collect_into_pending("s1", "fragmento", profile: bare)).to eq("t1")
      stop_serving(executor)
    end
  end

  it "session vars pin one conversation back to followup despite the platform default" do
    executor = build_executor(settings_store: settings({ "queue_mode" => "collect",
                                                         "debounce_ms" => 50 }))
    executor.supervised = true
    allow(executor).to receive(:create_chat).and_return(FakeChat.new)
    session_store.update_vars("s1", { "queue_mode" => "followup" })
    bare = profile({})

    Sync do |top|
      command = Insika::Command.build(:send_message, { agent: "a", message: "oi" })
      task = task_store.create(command: command.to_h, session_id: "s1", id: "t1")
      executor.spawn_in_session(task, profile: bare)
      top.sleep(0.01)

      expect(executor.collect_into_pending("s1", "fragmento", profile: bare)).to be_nil
      stop_serving(executor)
    end
  end
end
