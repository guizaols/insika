# frozen_string_literal: true

require "spec_helper"
require "async"
# O Executor os carrega lazy em create_chat; aqui create_chat é stubado, então
# requeremos explícito (mesma disciplina do executor_chat_spec).
require "harness/tools/load_skill"
require "harness/tools/tool_search"

# Smoke E2E da fatia B (P2B): CommandBus + SendMessage + Executor + RubyLLM
# mockado (FakeChat via stub de create_chat). Componentes REAIS: CapabilityRegistry,
# ToolRegistry, Policy::Engine+ToolAllowlist, ToolCatalog, AgentProfile — só o
# `chat` é duplo. Sem dimensão de crash/reboot (a fatia B não a tem), então
# in-process, sem subprocess (diferente do smoke_resume da fatia A).
RSpec.describe "smoke E2E: capability resolution + tool search (fatia B)", :smoke do
  # Tool crua o bastante p/ Registry/ToolEnvelope/ResolvedTool (só respond_to?).
  class FakeCapTool
    def initialize(name) = (@name = name)
    def name = @name
    def description = "fake #{@name}"
    def parameters = {} # tool RubyLLM real sempre responde a isso (usado por tool_search#describe)
    def call(_args = {}) = "executed:#{@name}"
  end

  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { SpyEventStream.new }

  let(:tool_registry)       { Harness::ToolRegistry.new }
  let(:capability_registry) { Harness::CapabilityRegistry.new }
  let(:tool_catalog)        { Harness::ToolCatalog.new(tool_registry: tool_registry) }

  let(:policy_registry) do
    Harness::PolicyRegistry.new.tap { |r| r.register(:tool_allowlist, Harness::Policy::Builtin::ToolAllowlist) }
  end
  let(:policy_engine) { Harness::Policy::Engine.new(policy_registry: policy_registry, event_stream: event_stream) }

  let(:profiles) do
    {
      "cap_top" => Harness::AgentProfile.build(
        id: "cap_top", model: "fake", policies: [:tool_allowlist], capabilities: [:browse]
      ),
      "cap_deny_top" => Harness::AgentProfile.build(
        id: "cap_deny_top", model: "fake", policies: [:tool_allowlist],
        capabilities: [:browse], tools_deny: ["browser_b"]
      ),
      "cap_ambiguous" => Harness::AgentProfile.build(
        id: "cap_ambiguous", model: "fake", policies: [:tool_allowlist], capabilities: [:ambiguous_cap]
      ),
      "deferred_ok" => Harness::AgentProfile.build(
        id: "deferred_ok", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email], tools_deferred: ["send_email"]
      ),
      "deferred_nil" => Harness::AgentProfile.build(
        id: "deferred_nil", model: "fake", policies: [:tool_allowlist],
        tools_allow: %w[eager_tool send_email] # tools_deferred: nil (default) — paridade
      )
    }
  end

  let(:executor) do
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: policy_engine,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: tool_registry, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream,
      capability_registry: capability_registry, tool_catalog: tool_catalog
    )
  end

  let(:bus) do
    Harness::CommandBus.new.tap do |b|
      b.register(:send_message,
                 Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store,
                                                    task_store: task_store, executor: executor))
    end
  end

  before do
    %w[browser_a browser_b browser_c impl_x impl_y eager_tool send_email].each do |n|
      tool_registry.register(n) { FakeCapTool.new(n) }
    end

    # :browse — a=10/p1, b=50/p2, c=100/p3 mas INDISPONÍVEL. Com o filtro, "b" vence.
    capability_registry.register(:browse, impl_name: "browser_a", kind: :tool, plugin: "p1", priority: 10)
    capability_registry.register(:browse, impl_name: "browser_b", kind: :tool, plugin: "p2", priority: 50)
    capability_registry.register(:browse, impl_name: "browser_c", kind: :tool, plugin: "p3", priority: 100,
                                          available: -> { false })

    # :ambiguous_cap — 2 providers do MESMO plugin, mesma priority (L4 -> Ambiguous).
    capability_registry.register(:ambiguous_cap, impl_name: "impl_x", kind: :tool, plugin: "pA", priority: 50)
    capability_registry.register(:ambiguous_cap, impl_name: "impl_y", kind: :tool, plugin: "pA", priority: 50)
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # One-shot (sem session_id) não passa pelo SessionActor — vai direto ao spawn.
  def run_turn(agent:, chat: FakeChat.new)
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = bus.dispatch(Harness::Command.build(:send_message, { agent: agent, message: "oi" }))
      100.times do
        t = task_store.find(result[:task_id])
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    [task_store.find(result[:task_id]), chat]
  end

  it "resolve p/ maior priority disponível; descarta indisponível; emite :capability_resolved (nome estável)" do
    task, chat = run_turn(agent: "cap_top")
    expect(task.status).to eq(:completed)

    resolved = event_stream.events.find { |e| e.type == :capability_resolved }
    expect(resolved.data[:capability]).to eq(:browse)
    expect(resolved.data[:chosen]).to eq("browser_b") # "b" (50) vence "a" (10)
    expect(resolved.data[:candidates].map { |c| c[:impl_name] }).to contain_exactly("browser_a", "browser_b")

    tool = chat.tools.find { |t| t.respond_to?(:name) && t.name.to_s == "browse" }
    expect(tool).not_to be_nil                 # nome ESTÁVEL exposto ao modelo (D4)
    expect(tool.impl_name).to eq("browser_b")  # impl real por trás (Envelope delega)
  end

  it "tools_deny filtra por impl_name DENTRO da resolução (não só depois)" do
    task, = run_turn(agent: "cap_deny_top") # tools_deny: ["browser_b"]
    expect(task.status).to eq(:completed)
    resolved = event_stream.events.select { |e| e.type == :capability_resolved }.last
    expect(resolved.data[:chosen]).to eq("browser_a") # "b" negado -> próximo elegível
  end

  it "empate mesmo-plugin -> CapabilityAmbiguous; turno falha em :capability; sem :capability_resolved" do
    task, = run_turn(agent: "cap_ambiguous")
    expect(task.status).to eq(:failed)
    expect(task.executions.last.error["class"]).to eq("Harness::CapabilityAmbiguous")
    expect(task.executions.last.error["stage"]).to eq("capability")
    expect(event_stream.types).to include(:task_failed, :error)
    expect(event_stream.events.select { |e| e.type == :capability_resolved }).to be_empty
  end

  it "deferred fora do prompt inicial; tool_search promove; chamável no mesmo turno; emite :tool_search" do
    initial_names = nil
    promoted_result = nil
    chat = FakeChat.new
    chat.script = proc do
      initial_names = tools.map { |t| t.name.to_s }
      ts = tools.find { |t| t.name.to_s == "tool_search" }
      ts.execute(query: "enviar email")
      promoted = tools.find { |t| t.name.to_s == "send_email" }
      promoted_result = promoted&.call({})
    end

    task, = run_turn(agent: "deferred_ok", chat: chat)
    expect(task.status).to eq(:completed)

    expect(initial_names).to include("eager_tool", "tool_search")
    expect(initial_names).not_to include("send_email") # deferred: fora do prompt inicial
    expect(promoted_result).to eq("executed:send_email") # promovida + chamável NO MESMO turno (D6)

    ev = event_stream.events.find { |e| e.type == :tool_search }
    expect(ev.data[:query]).to eq("enviar email")
    expect(ev.data[:matched]).to include("send_email")
  end

  it "tools_deferred nil -> paridade Fase 1 (tudo eager, sem tool_search de sistema)" do
    seen_names = nil
    chat = FakeChat.new
    chat.script = proc { seen_names = tools.map { |t| t.name.to_s } }

    task, = run_turn(agent: "deferred_nil", chat: chat)
    expect(task.status).to eq(:completed)

    expect(seen_names).to include("eager_tool", "send_email")
    expect(seen_names).not_to include("tool_search")
  end
end
