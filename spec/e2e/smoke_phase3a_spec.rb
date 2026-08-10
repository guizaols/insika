# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../lib/insika/server/a2a/app"

# E2E smoke for Phase 3 slice A (P3A): drives the REAL Server::A2A::App#rpc/#agent_card
# over a CommandBus + handlers (create_session/send_message/cancel_task) + REAL
# Executor, only the chat mocked (FakeChat via create_chat stub). Proves inbound
# A2A federation end to end, without an API key.
RSpec.describe "smoke E2E: A2A inbound adapter (slice A)", :smoke do
  let(:backend)          { Insika::Stores::Memory.new }
  let(:session_store)    { Insika::SessionStore.new(store: backend) }
  let(:task_store)       { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:event_stream)     { Insika::EventStream.new }
  let(:skill_catalog)    { Insika::SkillCatalog.new([]) }
  let(:profiles)         { { "assistant" => Insika::AgentProfile.build(id: "assistant", model: "fake", base_prompt: "SOUL") } }

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: skill_catalog,
      profiles: profiles, session_store: session_store, task_store: task_store,
      checkpoint_store: checkpoint_store, event_stream: event_stream
    )
  end

  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:create_session, Insika::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
      b.register(:send_message, Insika::Commands::SendMessage.new(profiles: profiles, session_store: session_store, task_store: task_store, executor: executor))
      b.register(:cancel_task, Insika::Commands::CancelTask.new(task_store: task_store, executor: executor))
    end
  end

  let(:a2a) do
    Insika::Server::A2A::App.new(
      command_bus: bus, task_store: task_store, session_store: session_store,
      profiles: profiles, skill_catalog: skill_catalog,
      config: { a2a_agent: "assistant", base_url: "https://h.example" }
    )
  end

  def rpc(method, params = {}, id: "1")
    a2a.rpc({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  TERMINAL = %w[completed failed cancelled].freeze

  # message/send + poll until the Task finishes (the turn runs in an async fiber).
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

  it "message/send creates the Task via send_message (same bus) and returns an A2A Task" do
    chat = FakeChat.new
    allow(executor).to receive(:create_chat).and_return(chat)
    Sync do
      res = rpc("message/send", { "message" => { "parts" => [{ "kind" => "text", "text" => "oi" }] } })
      task = res[:result]
      expect(task[:kind]).to eq("task")
      expect(task[:id]).to be_a(String)
      expect(task[:contextId]).to be_a(String) # session created (server-assigned)
      # the turn may run eagerly under Sync (synchronous FakeChat) -> any valid A2A
      # state works; the point is the Task being projected correctly.
      expect(%w[submitted working completed]).to include(task[:status][:state])
    end
  end

  it "tasks/get projects 'completed' with status.message (transcript content)" do
    task = send_and_finish(final: "olá, tudo bem?")
    res = rpc("tasks/get", { "id" => task[:id] })
    expect(res[:result][:status][:state]).to eq("completed")
    expect(res[:result][:status][:message][:parts].first[:text]).to eq("olá, tudo bem?")
  end

  it "agent-card for the configured agent (streaming:false)" do
    card = a2a.agent_card
    expect(card[:name]).to eq("assistant")
    expect(card[:url]).to eq("https://h.example/a2a")
    expect(card[:capabilities][:streaming]).to be(false)
  end

  it "tasks/get for a nonexistent id -> -32001" do
    expect(rpc("tasks/get", { "id" => "nope" })[:error][:code]).to eq(Insika::Server::A2A::Errors::TASK_NOT_FOUND)
  end

  it "unknown method -> -32601 (never leaks)" do
    expect(rpc("foo/bar")[:error][:code]).to eq(Insika::Server::A2A::Errors::METHOD_NOT_FOUND)
  end

  it "tasks/cancel of a terminal task dispatches without error and projects the Task" do
    task = send_and_finish
    Sync do
      res = rpc("tasks/cancel", { "id" => task[:id] })
      expect(res).to have_key(:result) # cancel_task no-op on a terminal; valid envelope, no exception
      expect(res[:result][:id]).to eq(task[:id])
    end
  end
end
