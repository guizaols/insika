# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../server/a2a/app"

# Smoke E2E da Fase 3 fatia A (P3A): dirige o Server::A2A::App#rpc/#agent_card
# REAL sobre um CommandBus + handlers (create_session/send_message/cancel_task) +
# Executor REAIS, só o chat mockado (FakeChat via create_chat stub). Prova a
# federação A2A inbound ponta a ponta, sem chave de API.
RSpec.describe "smoke E2E: adapter A2A inbound (fatia A)", :smoke do
  let(:backend)          { Harness::Stores::Memory.new }
  let(:session_store)    { Harness::SessionStore.new(store: backend) }
  let(:task_store)       { Harness::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Harness::CheckpointStore.new(store: backend) }
  let(:event_stream)     { Harness::EventStream.new }
  let(:skill_catalog)    { Harness::SkillCatalog.new([]) }
  let(:profiles)         { { "assistant" => Harness::AgentProfile.build(id: "assistant", model: "fake", base_prompt: "SOUL") } }

  let(:executor) do
    Harness::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: skill_catalog,
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:bus) do
    Harness::CommandBus.new(event_stream: event_stream).tap do |b|
      b.register(:create_session, Harness::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
      b.register(:send_message, Harness::Commands::SendMessage.new(profiles: profiles, session_store: session_store, task_store: task_store, executor: executor))
      b.register(:cancel_task, Harness::Commands::CancelTask.new(task_store: task_store, executor: executor))
    end
  end

  let(:a2a) do
    Harness::Server::A2A::App.new(
      command_bus: bus, task_store: task_store, session_store: session_store,
      profiles: profiles, skill_catalog: skill_catalog,
      config: { a2a_agent: "assistant", base_url: "https://h.example" }
    )
  end

  def rpc(method, params = {}, id: "1")
    a2a.rpc({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # message/send + poll até a Task terminar (o turno roda em fiber assíncrono).
  def send_and_finish(text: "oi", final: "olá!")
    chat = FakeChat.new
    chat.final_content = final
    allow(executor).to receive(:create_chat).and_return(chat)
    result = nil
    Sync do |parent|
      result = rpc("message/send", { "message" => { "parts" => [{ "kind" => "text", "text" => text }] } })
      task_id = result[:result][:id]
      100.times do
        t = task_store.find(task_id)
        break if t && TERMINAL.include?(t.status.to_s)

        parent.sleep(0.005)
      end
    end
    result[:result]
  end

  it "message/send cria a Task via send_message (mesmo bus) e devolve uma A2A Task" do
    chat = FakeChat.new
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      res = rpc("message/send", { "message" => { "parts" => [{ "kind" => "text", "text" => "oi" }] } })
      task = res[:result]
      expect(task[:kind]).to eq("task")
      expect(task[:id]).to be_a(String)
      expect(task[:contextId]).to be_a(String) # sessão criada (server-assigned)
      # o turno pode rodar eager sob Sync (FakeChat síncrono) -> qualquer estado
      # A2A válido serve; o ponto é a Task projetada corretamente.
      expect(%w[submitted working completed]).to include(task[:status][:state])
    end
  end

  it "tasks/get projeta 'completed' com status.message (conteúdo do transcript)" do
    task = send_and_finish(final: "olá, tudo bem?")
    res = rpc("tasks/get", { "id" => task[:id] })
    expect(res[:result][:status][:state]).to eq("completed")
    expect(res[:result][:status][:message][:parts].first[:text]).to eq("olá, tudo bem?")
  end

  it "agent-card do agente configurado (streaming:false)" do
    card = a2a.agent_card
    expect(card[:name]).to eq("assistant")
    expect(card[:url]).to eq("https://h.example/a2a")
    expect(card[:capabilities][:streaming]).to be(false)
  end

  it "tasks/get de id inexistente -> -32001" do
    expect(rpc("tasks/get", { "id" => "nope" })[:error][:code]).to eq(Harness::Server::A2A::Errors::TASK_NOT_FOUND)
  end

  it "método desconhecido -> -32601 (nunca vaza)" do
    expect(rpc("foo/bar")[:error][:code]).to eq(Harness::Server::A2A::Errors::METHOD_NOT_FOUND)
  end

  it "tasks/cancel de uma task terminal despacha sem erro e projeta a Task" do
    task = send_and_finish
    Sync do
      res = rpc("tasks/cancel", { "id" => task[:id] })
      expect(res).to have_key(:result) # cancel_task no-op numa terminal; envelope válido, sem exceção
      expect(res[:result][:id]).to eq(task[:id])
    end
  end
end
