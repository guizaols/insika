# frozen_string_literal: true

require "spec_helper"
require "async"
# create_chat is stubbed in the smoke -> we require the builtins explicitly.
require "insika/tools/load_skill"
require "insika/tools/tool_search"
require "insika/tools/remember"

# E2E smoke for slice C (P2C): CommandBus + SendMessage + Executor + MemoryStore +
# ContextBuilder REAL, only the chat mocked. Uses the real ContextBuilder (with the
# Memory provider) — FakeContextBuilder does NOT run providers, so it would give a
# false green on the cross-session read criterion. Tenant comes from the Command
# (proves the D6 threading).
RSpec.describe "smoke E2E: cross-session memory (slice C)", :smoke do
  let(:backend)          { Insika::Stores::Memory.new }
  let(:session_store)    { Insika::SessionStore.new(store: backend) }
  let(:task_store)       { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }
  let(:memory)           { Insika::MemoryStore.new(store: backend) }

  # REAL ContextBuilder with the Memory provider (+ Prompt for the base identity).
  let(:context_builder) do
    providers = [
      Insika::Context::Providers::Prompt.new(base: "", files: [], catalog: nil),
      Insika::Context::Providers::Memory.new(store: memory)
    ]
    Insika::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: Insika::Hooks.new)
  end

  let(:profiles) do
    {
      "mem_on"  => Insika::AgentProfile.build(id: "mem_on", model: "fake", base_prompt: "SOUL", memory: true),
      "mem_off" => Insika::AgentProfile.build(id: "mem_off", model: "fake", base_prompt: "SOUL") # memory: nil
    }
  end

  let(:executor) do
    Insika::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream, memory_store: memory
    )
  end

  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:send_message,
                 Insika::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end

  TERMINAL = %w[completed failed cancelled].freeze

  def run_turn(agent:, tenant: "acme", chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = bus.dispatch(Insika::Command.build(:send_message, { agent: agent, message: "oi" }, tenant: tenant))
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end

  it "session 1: agent writes a fact via remember; :memory_written; persists under the tenant" do
    chat = FakeChat.new
    chat.script = proc do
      tools.find { |t| t.name.to_s == "remember" }.execute(value: "premium", key: "plano")
    end

    task, = run_turn(agent: "mem_on", chat: chat)
    expect(task.status).to eq(:completed)

    ev = event_stream.events.find { |e| e.type == :memory_written }
    expect(ev.data).to eq({ kind: "fact", key: "plano" })
    expect(memory.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
  end

  it "session 2 (same tenant): the Memory provider recovers the fact in the system's <memory>" do
    memory.put_fact(tenant: "acme", key: "plano", value: "premium") # written in a previous session

    _task, chat = run_turn(agent: "mem_on")
    expect(chat.instructions).to include("<memory>", %(<fact key="plano">premium</fact>))
  end

  it "note (remember without key) appears in the next session's context" do
    memory.add_note(tenant: "acme", text: "cliente prefere email", at: "2026-01-01T00:00:00Z")

    _task, chat = run_turn(agent: "mem_on")
    expect(chat.instructions).to include("<note>cliente prefere email</note>")
  end

  it "parity: a memory:nil agent gets neither <memory> nor the remember tool" do
    memory.put_fact(tenant: "acme", key: "plano", value: "premium")
    seen = nil
    chat = FakeChat.new
    chat.script = proc { seen = tools.map { |t| t.name.to_s } }

    _task, = run_turn(agent: "mem_off", chat: chat)
    expect(chat.instructions.to_s).not_to include("<memory>")
    expect(seen).not_to include("remember")
  end
end
