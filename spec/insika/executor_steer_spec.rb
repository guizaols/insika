# frozen_string_literal: true

require "spec_helper"
require "async"

# — the `steer` door as the Executor exposes it, and what happens to a
# message the run could not absorb. Every guard here exists so a wiring that did NOT ask
# for steering behaves exactly as it did before the feature.
RSpec.describe "Insika::Executor + the steer door" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:steering) { profile({ queue_mode: "steer" }) }

  def profile(limits) = Insika::AgentProfile.build(id: "a", model: "gpt", limits: limits)

  def build_executor(profiles: {})
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([]), hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    ).tap { |ex| ex.supervised = true }
  end

  # The supervisor is long-lived: a Sync block will not return while it is alive.
  def stop_serving(executor)
    executor.stop_session_actors
    executor.instance_variable_get(:@supervisor)&.stop
  end

  # The turn's TaskActor. Reached through the ivar on purpose: the registry is the
  # Executor's own bookkeeping and production has no reason to expose it.
  def running_actor(executor, task_id) = executor.instance_variable_get(:@running)[task_id]

  # A turn that blocks in `ask` until released, so there is a RUNNING turn to steer into.
  def blocking_chat
    chat = FakeChat.new
    chat.script = proc { loop { Async::Task.current.sleep(0.01) } }
    chat
  end

  def spawn_turn(executor, id: "t1", message: "queria saber do pedido", chat: blocking_chat)
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "a", message: message })
    task = task_store.create(command: command.to_h, session_id: "s1", id: id)
    executor.spawn_in_session(task, profile: steering)
    task
  end

  before { session_store.create(id: "s1") }

  it "returns nil when the executor is not serving — at boot/recovery there is no door" do
    executor = build_executor
    executor.supervised = false

    Sync { expect(executor.steer_into_running("s1", "1234", profile: steering)).to be_nil }
  end

  it "returns nil for followup, which is what every agent gets by default" do
    executor = build_executor

    Sync do |top|
      spawn_turn(executor)
      top.sleep(0.02)

      expect(executor.steer_into_running("s1", "1234", profile: profile({}))).to be_nil
      stop_serving(executor)
    end
  end

  it "returns nil when nothing is running on the session" do
    executor = build_executor

    Sync { expect(executor.steer_into_running("s1", "1234", profile: steering)).to be_nil }
  end

  it "posts into the RUNNING turn and answers with its id" do
    executor = build_executor

    Sync do |top|
      spawn_turn(executor)
      top.sleep(0.02)

      expect(executor.steer_into_running("s1", "1234567", profile: steering)).to eq("t1")
      expect(running_actor(executor, "t1").user_messages_posted).to eq(1)
      stop_serving(executor)
    end
  end

  it "stops at steer_max_messages: the overflow becomes a turn of its own (followup)" do
    executor = build_executor
    bounded = profile({ queue_mode: "steer", steer_max_messages: 2 })

    Sync do |top|
      allow(executor).to receive(:create_chat).and_return(blocking_chat)
      command = Insika::Command.build(:send_message, { agent: "a", message: "oi" })
      task = task_store.create(command: command.to_h, session_id: "s1", id: "t1")
      executor.spawn_in_session(task, profile: bounded)
      top.sleep(0.02)

      expect(executor.steer_into_running("s1", "um", profile: bounded)).to eq("t1")
      expect(executor.steer_into_running("s1", "dois", profile: bounded)).to eq("t1")
      expect(executor.steer_into_running("s1", "três", profile: bounded)).to be_nil
      stop_serving(executor)
    end
  end

  # a message nothing read is a message a PERSON typed. It becomes the next turn
  # rather than evaporating, which is `followup` arrived at late.
  it "releases a message the run never absorbed as a follow-up turn" do
    executor = build_executor(profiles: { "a" => steering })

    Sync do |top|
      # A turn with no tool call at all: no batch ever closes, so no boundary arrives.
      # It takes its time so the message really lands mid-run.
      chat = FakeChat.new
      chat.script = proc { Async::Task.current.sleep(0.05) }
      spawn_turn(executor, chat: chat)
      top.sleep(0.02)
      running_actor(executor, "t1").post(:user_message, "1234567")
      top.sleep(0.2)

      released = task_store.each_id.reject { |id| id == "t1" }
      expect(released.size).to eq(1)
      expect(task_store.find(released.first).command["payload"]["message"]).to eq("1234567")
      expect(event_stream.types).to include(:turn_steer_released)
      stop_serving(executor)
    end
  end

  it "a turn that absorbed everything releases nothing" do
    executor = build_executor(profiles: { "a" => steering })

    Sync do |top|
      chat = FakeChat.new
      # One tool call, so the batch boundary arrives and the injector consumes the message.
      chat.script = proc do
        Async::Task.current.sleep(0.05) # the message lands while the tool is in flight
        fire_tool_call(name: "search")
        fire_tool_result("ok")
        fire_tool_result_message("ok")
      end
      spawn_turn(executor, chat: chat)
      top.sleep(0.02)
      running_actor(executor, "t1").post(:user_message, "1234567")
      top.sleep(0.2)

      expect(task_store.each_id.to_a).to eq(["t1"])
      expect(event_stream.types).to include(:turn_steered)
      expect(event_stream.types).not_to include(:turn_steer_released)

      # it persists as what it is, with NO new persistence code and no origin:
      # `recorded_turn_messages` slices everything the chat gained past the baseline, and
      # an absent origin on a `user` message already means "a person typed it".
      steered = session_store.find("s1").messages.find { |m| m["content"] == "1234567" }
      expect(steered["role"]).to eq("user")
      expect(steered.key?("origin")).to be(false)
      expect(Insika::MessageOrigin.customer?(steered)).to be(true)
      stop_serving(executor)
    end
  end
end
