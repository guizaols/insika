# frozen_string_literal: true

require "spec_helper"
require "async"

# End-to-end EdgeLimiter behavior through the real Executor pipeline (
# the blocked turn completes gracefully with ZERO LLM calls AND stays out
# of the session history (a flood must not bloat the session / poison the context).
RSpec.describe "Insika::Executor + EdgeLimiter" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:guardrails) { Insika::Safety::Factory.new }
  let(:ledger) { Insika::UsageLedger.new(store: Insika::Stores::Memory.new) }
  let(:profile) do
    Insika::AgentProfile.build(id: "example-agent", model: "gpt", base_prompt: "SOUL",
                                limits: { chat_rate_limit: 1 })
  end

  def build_executor
    edge = Insika::EdgeLimiter.new(ledger: ledger)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: Insika::MiddlewareStack.new([edge, guardrails.input_guardrail]),
      hooks: Insika::Hooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: {}, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      content_filter_factory: guardrails.content_filter_factory
    )
  end

  def make_task(message, id:)
    command = Insika::Command.build(:send_message, { agent: "example-agent", message: message })
    task_store.create(command: command.to_h, session_id: "s1", id: id)
  end

  def run_turn(executor, task, fake_chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(fake_chat)
    Sync do
      executor.spawn(task, profile: profile)
      executor.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  before { session_store.create(id: "s1") }

  it "blocks the turn past the limit with zero LLM calls and keeps it OUT of the session" do
    executor = build_executor
    run_turn(executor, make_task("oi", id: "t1"))
    after_first = session_store.find("s1").messages.size
    expect(after_first).to be > 0 # the admitted turn persisted normally

    chat = FakeChat.new
    run_turn(executor, make_task("oi de novo", id: "t2"), fake_chat: chat)

    expect(chat.asked).to be_nil # the LLM was never touched
    expect(task_store.find("t2").status).to eq(:completed) # graceful, not a failure

    blocked = event_stream.events.find { |e| e.type == :guardrail_blocked }
    expect(blocked.data).to include(category: "rate_limit", source: "edge")

    # the flood exchange did NOT enter the session history (audit = the event)
    expect(session_store.find("s1").messages.size).to eq(after_first)
  end
end
