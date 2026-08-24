# frozen_string_literal: true

require "spec_helper"
require "async"
require "insika/tools/update_briefing" # the Executor loads it lazily; explicit here in the test

#   — the acceptance gate, end-to-end. A turn WRITES the briefing
# through the real tool, the NEXT turn's context RENDERS it as a <briefing>
# block, and a RESUME re-reads it from the store (it survives the transcript).
RSpec.describe "Insika::Executor — briefing end-to-end " do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "fake", base_prompt: "SOUL",
                                              briefing_fields: %w[size budget]) }
  let(:profiles) { { "sales" => profile } }

  # REAL ContextBuilder: the Briefing provider reads the session record, the
  # Session provider seeds history — the assembled system is what the model sees.
  let(:context_builder) do
    providers = [
      Insika::Context::Providers::Prompt.new(base: "", catalog: nil),
      Insika::Context::Providers::Briefing.new(session_store: session_store),
      Insika::Context::Providers::Session.new(session_store: session_store)
    ]
    Insika::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: Insika::Hooks.new)
  end

  let(:executor) do
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:resume_handler) do
    Insika::Commands::ResumeTask.new(profiles: profiles, task_store: task_store,
                                     checkpoint_store: checkpoint_store, executor: executor)
  end

  before { session_store.create(id: "s1") }

  def run_turn(chat, task_id: "t1")
    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: task_id)
    Sync do
      executor.spawn(task_store.find(task_id), profile: profile)
      executor.instance_variable_get(:@running)[task_id]&.wait
    end
    [task_store.find(task_id), chat]
  end

  it "turn 1: the model calls update_briefing; the session record persists" do
    chat = FakeChat.new
    chat.script = proc do
      tools.find { |t| t.name.to_s == "update_briefing" }.execute(field: "size", value: "M")
    end

    task, = run_turn(chat)
    expect(task.status).to eq(:completed)
    expect(session_store.find("s1").briefing["fields"]).to eq("size" => "M")

    ev = event_stream.events.find { |e| e.type == :briefing_updated }
    expect(ev.data).to eq(kind: "field", field: "size", value: "M")
  end

  it "turn 2: the assembled context system renders the <briefing> block from the store" do
    session_store.update_briefing("s1", field: "size", value: "M")

    chat = FakeChat.new
    chat.final_content = "ok"
    _task, chat = run_turn(chat, task_id: "t2")

    expect(chat.instructions).to include("<briefing>")
    expect(chat.instructions).to include("  size: M")
    expect(chat.instructions).to include("still missing: budget")
  end

  it "the briefing survives beyond the transcript — a RESUME re-reads it from the store" do
    session_store.update_briefing("s1", field: "size", value: "M")

    # a paused task with a checkpoint: the resume path re-dispatches from it.
    command = Insika::Command.build(:send_message, { agent: "sales", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: "t3")
    task_store.begin_execution("t3")
    task_store.transition("t3", to: :running)
    task_store.transition("t3", to: :paused)
    checkpoint_store.save(Insika::Checkpoint.new(
                            task_id: "t3", turn: 1, session_id: "s1", agent_id: "sales",
                            messages: [{ role: "user", content: "oi" }],
                            completed_side_effects: [], created_at: nil
                          ))

    chat = FakeChat.new
    chat.final_content = "ok"
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      resume_handler.call(Insika::Command.build(:resume_task, { task_id: "t3" }))
      executor.instance_variable_get(:@running)["t3"]&.wait
    end

    expect(task_store.find("t3").status).to eq(:completed)
    expect(chat.instructions).to include("<briefing>", "  size: M", "still missing: budget")
  end

  it "parity: an agent without briefing_fields gets neither the tools nor the block" do
    plain = Insika::AgentProfile.build(id: "plain", model: "fake", base_prompt: "SOUL")
    seen = nil
    chat = FakeChat.new
    chat.script = proc { seen = tools.map { |t| t.name.to_s } }

    allow(executor).to receive(:create_chat).and_return(chat)
    command = Insika::Command.build(:send_message, { agent: "plain", message: "oi" })
    task_store.create(command: command.to_h, session_id: "s1", id: "t4")
    Sync do
      executor.spawn(task_store.find("t4"), profile: plain)
      executor.instance_variable_get(:@running)["t4"]&.wait
    end

    expect(chat.instructions.to_s).not_to include("<briefing>")
    expect(seen).not_to include("update_briefing", "set_next_step")
  end
end