# frozen_string_literal: true

require "spec_helper"
require "async"

# the `interrupt` door, and the boundary that makes it mean something.
#
# "Abandon" here is Insika's existing cancellation semantics, unchanged: `:cancel` is
# observed only at a stage boundary, so a tool call in flight finishes. What this PR adds
# is one boundary BEFORE the answer is published — without it the customer read the answer
# of a turn that then terminated `:cancelled` and persisted nothing.
RSpec.describe "Insika::Executor + the interrupt door" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:interrupting) { profile({ queue_mode: "interrupt" }) }

  def profile(limits) = Insika::AgentProfile.build(id: "a", model: "gpt", limits: limits)

  def build_executor
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([]), hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    ).tap { |ex| ex.supervised = true }
  end

  def stop_serving(executor)
    executor.stop_session_actors
    executor.instance_variable_get(:@supervisor)&.stop
  end

  # A turn that takes its time inside `ask`, so a message can arrive mid-run.
  def slow_chat(seconds = 0.06)
    chat = FakeChat.new
    chat.script = proc { Async::Task.current.sleep(seconds) }
    chat
  end

  def spawn_turn(executor, chat:, profile: interrupting, id: "t1")
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "a", message: "cadê meu pedido?" })
    task = task_store.create(command: command.to_h, session_id: "s1", id: id)
    executor.spawn_in_session(task, profile: profile)
    task
  end

  before { session_store.create(id: "s1") }

  it "returns nil for followup — the default abandons nothing" do
    executor = build_executor

    Sync do |top|
      spawn_turn(executor, chat: slow_chat(0.3), profile: profile({}))
      top.sleep(0.02)

      expect(executor.interrupt_running("s1", profile: profile({}))).to be_nil
      stop_serving(executor)
    end
  end

  it "returns nil when nothing is running" do
    executor = build_executor

    Sync { expect(executor.interrupt_running("s1", profile: interrupting)).to be_nil }
  end

  it "abandons the running turn: :cancelled, and the stale answer is NEVER published" do
    executor = build_executor

    Sync do |top|
      spawn_turn(executor, chat: slow_chat)
      top.sleep(0.02)

      expect(executor.interrupt_running("s1", profile: interrupting, replaced_by: "t2")).to eq("t1")
      top.sleep(0.2)

      expect(task_store.find("t1").status).to eq(:cancelled)
      expect(event_stream.types).to include(:turn_interrupted, :task_cancelled)
      # The whole point: the customer does not read the answer to the question they
      # already replaced. Nothing was persisted either, so the transcript and what the
      # customer saw still agree.
      expect(event_stream.types).not_to include(:content)
      expect(Array(session_store.find("s1").messages)).to be_empty
      stop_serving(executor)
    end
  end

  it "names what replaced the abandoned turn" do
    executor = build_executor

    Sync do |top|
      spawn_turn(executor, chat: slow_chat)
      top.sleep(0.02)
      executor.interrupt_running("s1", profile: interrupting, replaced_by: "t2")

      data = event_stream.events.find { |e| e.type == :turn_interrupted }.data
      expect(data).to eq({ task_id: "t1", replaced_by: "t2" })
      top.sleep(0.2)
      stop_serving(executor)
    end
  end

  # The weaker guarantee, stated as a spec so nobody reads "interrupt" as "abort": the
  # tool batch is one unit of work. Cancelling the not-yet-started calls would leave it
  # half applied, and faking failures would teach the model that tools failed.
  it "lets a tool call in flight finish, and records its result" do
    executor = build_executor
    ran = []

    Sync do |top|
      chat = FakeChat.new
      chat.script = proc do
        fire_tool_call(name: "search")
        Async::Task.current.sleep(0.08) # the cancel lands while this is in flight
        ran << :tool_finished
        fire_tool_result("ok")
        fire_tool_result_message("ok")
      end
      spawn_turn(executor, chat: chat)
      top.sleep(0.03)
      executor.interrupt_running("s1", profile: interrupting)
      top.sleep(0.25)

      expect(ran).to eq([:tool_finished])
      expect(event_stream.types).to include(:tool_result)
      expect(task_store.find("t1").status).to eq(:cancelled)
      stop_serving(executor)
    end
  end
end
