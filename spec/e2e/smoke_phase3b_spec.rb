# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../server/a2a/app"
require_relative "../../server/a2a/client"
require "harness/tools/a2a_remote"

# E2E smoke for Phase 3 slice B (P3B): LOOPBACK FEDERATION outbound→inbound
# in-process. The "remote" is our own inbound A2A::App (slice A). A loopback http
# routes post_json -> worker_inbound.rpc. Proves federation end to end in BOTH
# directions, without network or API key.
RSpec.describe "smoke E2E: A2A loopback federation (slice B)", :smoke do
  # Loopback Http: instead of network, calls the worker's inbound A2A::App. The
  # JSON round-trip is FAITHFUL to the wire — it converts the inbound's symbol-keyed
  # envelope into string keys, as a real HTTP POST would.
  LoopbackHttp = Struct.new(:inbound) do
    def post_json(_url, body) = JSON.parse(JSON.generate(inbound.rpc(body)))
  end

  # Assembles a complete worker (inbound A2A::App + bus + Executor + FakeChat).
  # -> [inbound_app, executor, chat]. `policy` lets you force a failure (DenyAll).
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

  # The orchestrator's remote tool, pointing (via loopback) at the inbound worker.
  def remote_tool(inbound)
    client = Harness::Server::A2A::Client.new(http: LoopbackHttp.new(inbound), sleeper: ->(_s) {})
    Harness::Tools::A2ARemote.new(client: client, url: "loopback",
                                  tool_name: "remote_worker", description: "delega ao worker",
                                  event_stream: event_stream)
  end

  it "orchestrator delegates to the worker via A2A and receives the answer (end-to-end federation)" do
    inbound, = build_worker(final: "42")
    tool = remote_tool(inbound)

    result = nil
    Sync { result = tool.execute(message: "quanto é 6x7?") }

    expect(result).to eq("42") # the worker replied, via A2A loopback
    ev = events.find { |e| e.type == :a2a_call }
    expect(ev.data).to include(agent: "remote_worker", state: "completed")
    expect(ev.data[:remote_task_id]).to be_a(String)
  end

  it "failing worker -> the tool returns { error: } (the orchestrator's turn continues)" do
    inbound, = build_worker(policy: DenyAllPolicyEngine.new) # worker's turn -> :failed
    tool = remote_tool(inbound)

    result = nil
    Sync { result = tool.execute(message: "x") }

    expect(result).to be_a(Hash)
    expect(result[:error]).to be_a(String)
    expect(events.find { |e| e.type == :a2a_call }.data[:state]).to eq("failed")
  end
end
