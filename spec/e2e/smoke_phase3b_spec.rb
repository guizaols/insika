# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../server/a2a/app"
require_relative "../../server/a2a/client"
require "harness/tools/a2a_remote"

# Smoke E2E da Fase 3 fatia B (P3B): FEDERAÇÃO LOOPBACK outbound→inbound
# in-process. O "remoto" é o nosso próprio A2A::App inbound (fatia A). Um http de
# loopback roteia post_json -> worker_inbound.rpc. Prova a federação ponta a
# ponta nos DOIS sentidos, sem rede nem chave de API.
RSpec.describe "smoke E2E: federação A2A loopback (fatia B)", :smoke do
  # Http de loopback: em vez de rede, chama o A2A::App inbound do worker. O
  # round-trip por JSON é FIEL ao wire — converte o envelope symbol-keyed do
  # inbound em chaves string, como um POST HTTP real faria.
  LoopbackHttp = Struct.new(:inbound) do
    def post_json(_url, body) = JSON.parse(JSON.generate(inbound.rpc(body)))
  end

  # Monta um worker completo (inbound A2A::App + bus + Executor + FakeChat).
  # -> [inbound_app, executor, chat]. `policy` permite forçar falha (DenyAll).
  def build_worker(final: "42", policy: NullPolicyEngine.new)
    backend = Harness::Stores::Memory.new
    session_store = Harness::SessionStore.new(store: backend)
    task_store = Harness::TaskStore.new(store: backend)
    checkpoint_store = Harness::CheckpointStore.new(store: backend)
    events = Harness::EventStream.new
    profiles = { "worker" => Harness::AgentProfile.build(id: "worker", model: "fake", base_prompt: "W") }
    executor = Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: policy,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Harness::SkillCatalog.new([]),
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: events
    )
    bus = Harness::CommandBus.new.tap do |b|
      b.register(:create_session, Harness::Commands::CreateSession.new(session_store: session_store, event_stream: events))
      b.register(:send_message, Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store, task_store: task_store, executor: executor))
      b.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: task_store, executor: executor))
    end
    inbound = Harness::Server::A2A::App.new(
      command_bus: bus, task_store: task_store, session_store: session_store,
      profiles: profiles, skill_catalog: Harness::SkillCatalog.new([]),
      config: { a2a_agent: "worker", base_url: "loopback" }
    )
    chat = FakeChat.new.tap { |c| c.final_content = final }
    allow(executor).to receive(:create_chat).and_return(chat)
    [inbound, executor, chat]
  end

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  # O tool remoto do orchestrator, apontando (via loopback) ao worker inbound.
  def remote_tool(inbound)
    client = Harness::Server::A2A::Client.new(http: LoopbackHttp.new(inbound), sleeper: ->(_s) {})
    Harness::Tools::A2ARemote.new(client: client, url: "loopback",
                                  tool_name: "remote_worker", description: "delega ao worker",
                                  event_stream: event_stream)
  end

  it "orchestrator delega ao worker via A2A e recebe a resposta (federação ponta a ponta)" do
    inbound, = build_worker(final: "42")
    tool = remote_tool(inbound)

    result = nil
    Sync { result = tool.execute(message: "quanto é 6x7?") }

    expect(result).to eq("42") # o worker respondeu, via A2A loopback
    ev = events.find { |e| e.type == :a2a_call }
    expect(ev.data).to include(agent: "remote_worker", state: "completed")
    expect(ev.data[:remote_task_id]).to be_a(String)
  end

  it "worker que falha -> a tool devolve { error: } (o turno do orchestrator segue)" do
    inbound, = build_worker(policy: DenyAllPolicyEngine.new) # turno do worker -> :failed
    tool = remote_tool(inbound)

    result = nil
    Sync { result = tool.execute(message: "x") }

    expect(result).to be_a(Hash)
    expect(result[:error]).to be_a(String)
    expect(events.find { |e| e.type == :a2a_call }.data[:state]).to eq("failed")
  end
end
