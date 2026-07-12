# frozen_string_literal: true

require "spec_helper"
require "async"
# create_chat é stubado no smoke -> requeremos os builtins explícito.
require "harness/tools/load_skill"
require "harness/tools/tool_search"
require "harness/tools/remember"

# Smoke E2E da fatia C (P2C): CommandBus + SendMessage + Executor + MemoryStore +
# ContextBuilder REAIS, só o chat mockado. Usa ContextBuilder real (com o Memory
# provider) — o FakeContextBuilder NÃO roda providers, então daria falso-verde no
# critério de leitura cross-session. Tenant vem do Command (prova o threading D6).
RSpec.describe "smoke E2E: memória cross-session (fatia C)", :smoke do
  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }
  let(:memory)           { Harness::MemoryStore.new(store: backend) }

  # ContextBuilder REAL com o Memory provider (+ Prompt p/ a identidade base).
  let(:context_builder) do
    providers = [
      Harness::Context::Providers::Prompt.new(base: "", files: [], catalog: nil),
      Harness::Context::Providers::Memory.new(store: memory)
    ]
    Harness::ContextBuilder.new(providers: providers, event_stream: event_stream, hooks: Harness::Hooks.new)
  end

  let(:profiles) do
    {
      "mem_on"  => Harness::AgentProfile.build(id: "mem_on", model: "fake", base_prompt: "SOUL", memory: true),
      "mem_off" => Harness::AgentProfile.build(id: "mem_off", model: "fake", base_prompt: "SOUL") # memory: nil
    }
  end

  let(:executor) do
    Harness::Executor.new(
      context_builder: context_builder, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream, memory_store: memory
    )
  end

  let(:bus) do
    Harness::CommandBus.new.tap do |b|
      b.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end

  TERMINAL = %w[completed failed cancelled].freeze

  def run_turn(agent:, tenant: "acme", chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = bus.dispatch(Harness::Command.build(:send_message, { agent: agent, message: "oi" }, tenant: tenant))
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end

  it "sessão 1: agente grava um fato via remember; :memory_written; persiste no tenant" do
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

  it "sessão 2 (mesmo tenant): o Memory provider recupera o fato no <memory> do system" do
    memory.put_fact(tenant: "acme", key: "plano", value: "premium") # gravado numa sessão anterior

    _task, chat = run_turn(agent: "mem_on")
    expect(chat.instructions).to include("<memory>", %(<fact key="plano">premium</fact>))
  end

  it "note (remember sem key) aparece no contexto da sessão seguinte" do
    memory.add_note(tenant: "acme", text: "cliente prefere email", at: "2026-01-01T00:00:00Z")

    _task, chat = run_turn(agent: "mem_on")
    expect(chat.instructions).to include("<note>cliente prefere email</note>")
  end

  it "paridade: agente memory:nil não recebe <memory> nem a tool remember" do
    memory.put_fact(tenant: "acme", key: "plano", value: "premium")
    seen = nil
    chat = FakeChat.new
    chat.script = proc { seen = tools.map { |t| t.name.to_s } }

    _task, = run_turn(agent: "mem_off", chat: chat)
    expect(chat.instructions.to_s).not_to include("<memory>")
    expect(seen).not_to include("remember")
  end
end
