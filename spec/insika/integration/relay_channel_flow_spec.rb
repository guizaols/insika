# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../lib/insika/server/app"

# The whole loop, with real wiring: HTTP inbound -> Command -> Executor -> the turn's
# terminal -> outbox -> the consumer's callback. Only two things are doubles — the
# provider (FakeChat, like every turn spec) and the consumer's HTTP endpoint.
#
# This is the spec that would catch the seam being wrong, because every piece PR 1
# added has to agree for the last assertion to hold.
RSpec.describe "Integration: a relay message, answered and delivered" do
  # Stands in for the consumer's server. Records what it received, exactly as it
  # arrived on the wire.
  class ConsumerEndpointDouble
    attr_reader :received

    def initialize(status: 200)
      @status = status
      @received = []
    end

    def request(method:, url:, headers: {}, body: nil, timeout: nil)
      @received << { url: url, headers: headers, body: JSON.parse(body) }
      { status: @status, body: "" }
    end
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:inbound_log) { Insika::InboundLog.new(store: backend) }
  let(:event_stream) { Insika::EventStream.new }
  let(:profile) { Insika::AgentProfile.build(id: "support", model: "gpt", base_prompt: "SUPPORT") }
  let(:consumer) { ConsumerEndpointDouble.new }

  let(:channels) do
    Insika::ChannelRegistry.new.tap do |registry|
      registry.register("relay",
                        Insika::Channels::Relay.new(inbound_token: "in-tok",
                                                    deliver_url: "https://8.8.8.8/hook",
                                                    deliver_token: "out-tok", http: consumer))
    end
  end

  let(:delivery) do
    Insika::ChannelDelivery.new(channels: channels, outbox: outbox, session_store: session_store,
                                event_stream: event_stream, sleeper: ->(_s) {})
  end

  let(:executor) do
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "support" => profile }, session_store: session_store,
      task_store: task_store, checkpoint_store: checkpoint_store, event_stream: event_stream,
      channel_delivery: delivery
    )
  end

  let(:bus) do
    Insika::CommandBus.new.tap do |b|
      b.register(:send_message,
                 Insika::Commands::SendMessage.new(profiles: { "support" => profile },
                                                   session_store: session_store, task_store: task_store,
                                                   executor: executor, inbound_log: inbound_log))
      b.register(:create_session,
                 Insika::Commands::CreateSession.new(session_store: session_store, event_stream: event_stream))
    end
  end

  let(:app) do
    Insika::Server::App.new(
      command_bus: bus, event_stream: event_stream,
      session_store: session_store, task_store: task_store,
      channels: channels, config: { gateway_token: "gw" }
    )
  end

  before do
    allow(executor).to receive(:create_chat) do
      FakeChat.new.tap { |c| c.final_content = "Vou verificar o pedido 1234567 e te aviso!" }
    end
  end

  def inbound(body, auth: "Bearer in-tok")
    env = Rack::MockRequest.env_for("/channels/relay/events", method: "POST", input: JSON.generate(body))
    env["HTTP_AUTHORIZATION"] = auth
    app.call(env)
  end

  def post_and_wait(body)
    status = nil
    payload = nil
    Sync do |parent|
      status, _h, raw = inbound(body)
      payload = JSON.parse(raw.join)
      wait_terminal(parent, payload["task_id"])
      executor.stop_session_actors
    end
    [status, payload]
  end

  def wait_terminal(parent, task_id)
    100.times do
      task = task_store.find(task_id)
      break if task && %w[completed failed cancelled].include?(task.status.to_s)

      parent.sleep(0.005)
    end
  end

  let(:message) do
    { agent: "support", external_id: "5511999998888", event_id: "wamid.1",
      message: "cadê meu pedido 1234567?" }
  end

  it "acks 202, runs the turn, and POSTs the answer to the consumer" do
    status, body = post_and_wait(message)

    expect(status).to eq(202)
    expect(task_store.find(body["task_id"]).status).to eq(:completed)

    expect(consumer.received.size).to eq(1)
    delivered = consumer.received.first
    expect(delivered[:url]).to eq("https://8.8.8.8/hook")
    expect(delivered[:headers]["authorization"]).to eq("Bearer out-tok")
    expect(delivered[:body]).to eq(
      "external_id" => "5511999998888", "session_id" => "relay:5511999998888",
      "task_id" => body["task_id"], "content" => "Vou verificar o pedido 1234567 e te aviso!"
    )
  end

  it "leaves the outbox record delivered, with the delivery header naming it" do
    _status, body = post_and_wait(message)

    id = consumer.received.first[:headers]["x-insika-delivery"]
    record = Insika::OutboxStore.new(store: backend).find(id)
    expect(record.status).to eq(:delivered)
    expect(record.task_id).to eq(body["task_id"])
  end

  it "writes the session under the namespaced id, with the address the reply needs" do
    post_and_wait(message)

    session = session_store.find("relay:5511999998888")
    expect(session.vars).to include("channel" => "relay", "external_id" => "5511999998888")
    expect(session.messages.map { |m| m["content"] })
      .to eq(["cadê meu pedido 1234567?", "Vou verificar o pedido 1234567 e te aviso!"])
  end

  # The retry the whole feature exists for: the platform did not see our ack, so it
  # sent the same event again. One turn, one delivery.
  it "answers a retried event_id with duplicate: true and delivers once" do
    _status, first = post_and_wait(message)

    status, second = post_and_wait(message)
    expect(status).to eq(200)
    expect(second).to eq("task_id" => first["task_id"], "duplicate" => true)
    expect(consumer.received.size).to eq(1)
  end

  it "does not deliver a turn that arrived on another surface, on the same session" do
    post_and_wait(message)
    consumer.received.clear

    Sync do |parent|
      result = bus.dispatch(Insika::Command.build(
                              :send_message,
                              { agent: "support", message: "teste do operador",
                                session_id: "relay:5511999998888" }, transport: :http
                            ))
      wait_terminal(parent, result[:task_id])
      executor.stop_session_actors
    end

    expect(consumer.received).to be_empty
  end
end
