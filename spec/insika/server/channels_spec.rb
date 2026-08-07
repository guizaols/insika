# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/app"

# RFC-0011 §4.4 — ONE generic route family, and the transport does no translating.
# The cases that matter are the ones where a wrong answer costs the customer a
# duplicated message, and the ones where an open route costs money.
RSpec.describe "Insika::Server::App channels" do
  CHANNELS_GATEWAY_TOKEN = "gw-token"
  CHANNELS_RELAY_TOKEN = "relay-token"

  let(:bus) { ServerBusDouble.new { |_c| { task_id: "t-1" } } }
  let(:sessions) { ServerStoreDouble.new(nil) }

  def registry_with(channel, id: "relay")
    Insika::ChannelRegistry.new.tap { |r| r.register(id, channel) }
  end

  def relay_channel(**over)
    Insika::Channels::Relay.new(**{ inbound_token: CHANNELS_RELAY_TOKEN, deliver_url: "https://8.8.8.8/hook" }.merge(over))
  end

  def build_app(channels:, bus: self.bus, session_store: sessions)
    Insika::Server::App.new(
      command_bus: bus, event_stream: ServerEventStreamDouble.new,
      session_store: session_store, task_store: ServerStoreDouble.new(nil),
      channels: channels, config: { sync_timeout: 0.05, gateway_token: CHANNELS_GATEWAY_TOKEN }
    )
  end

  def post(app, path, body, auth: "Bearer #{CHANNELS_RELAY_TOKEN}")
    env = Rack::MockRequest.env_for(path, method: "POST", input: body)
    env["HTTP_AUTHORIZATION"] = auth if auth
    app.call(env)
  end

  def envelope(**over)
    JSON.generate({ "agent" => "support", "external_id" => "5511999998888",
                    "message" => "queria saber do pedido" }.merge(over.transform_keys(&:to_s)))
  end

  def body_of(resp) = JSON.parse(resp.join)

  it "404s when the deployment registers no channels (parity with /a2a)" do
    app = build_app(channels: Insika::ChannelRegistry.new)
    status, = post(app, "/channels/relay/events", envelope)
    expect(status).to eq(404)
  end

  it "404s for an id nobody registered" do
    app = build_app(channels: registry_with(relay_channel))
    status, = post(app, "/channels/slack/events", envelope)
    expect(status).to eq(404)
  end

  # The route skips the GATEWAY bearer because the channel carries its own — but
  # "its own" is the whole point: this must never be an ungated surface.
  describe "authentication (the channel's, not the gateway's)" do
    it "accepts the channel's bearer without the gateway token" do
      app = build_app(channels: registry_with(relay_channel))
      status, = post(app, "/channels/relay/events", envelope)
      expect(status).to eq(202)
    end

    it "401s a wrong or missing bearer" do
      app = build_app(channels: registry_with(relay_channel))
      expect(post(app, "/channels/relay/events", envelope, auth: "Bearer wrong").first).to eq(401)
      expect(post(app, "/channels/relay/events", envelope, auth: nil).first).to eq(401)
    end

    it "does NOT accept the gateway token instead" do
      app = build_app(channels: registry_with(relay_channel))
      expect(post(app, "/channels/relay/events", envelope, auth: "Bearer #{CHANNELS_GATEWAY_TOKEN}").first).to eq(401)
    end

    it "503s a channel with no credential configured (fail-closed, never open)" do
      app = build_app(channels: registry_with(relay_channel(inbound_token: "")))
      expect(post(app, "/channels/relay/events", envelope, auth: nil).first).to eq(503)
    end

    it "503s a channel that cannot authenticate at all" do
      naked = Class.new { def parse(_r, body:) = {} }.new
      app = build_app(channels: registry_with(naked))
      expect(post(app, "/channels/relay/events", envelope).first).to eq(503)
    end
  end

  it "422s a malformed envelope, before any turn exists" do
    app = build_app(channels: registry_with(relay_channel))
    status, = post(app, "/channels/relay/events", envelope(message: ""))
    expect(status).to eq(422)
    expect(bus.dispatched.map(&:type)).not_to include(:send_message)
  end

  describe "the dispatch" do
    it "creates the namespaced session with the channel's address on it" do
      app = build_app(channels: registry_with(relay_channel))
      post(app, "/channels/relay/events", envelope(vars: { "store" => "ocean-drop" }))

      create = bus.dispatched.find { |c| c.type == :create_session }
      expect(create.payload[:id]).to eq("relay:5511999998888")
      expect(create.payload[:vars]).to eq("store" => "ocean-drop", "channel" => "relay",
                                          "external_id" => "5511999998888")
    end

    # A caller must not be able to rewrite its own conversation's address by
    # smuggling the keys through `vars`.
    it "refuses to let the caller's vars overwrite channel/external_id" do
      app = build_app(channels: registry_with(relay_channel))
      post(app, "/channels/relay/events", envelope(vars: { "channel" => "web", "external_id" => "victim" }))

      create = bus.dispatched.find { |c| c.type == :create_session }
      expect(create.payload[:vars]).to include("channel" => "relay", "external_id" => "5511999998888")
    end

    it "tags the turn with the channel transport, which is what unlocks coalescing" do
      app = build_app(channels: registry_with(relay_channel))
      post(app, "/channels/relay/events", envelope)

      send_msg = bus.dispatched.find { |c| c.type == :send_message }
      expect(send_msg.meta[:transport]).to eq(:"channel:relay")
      expect(send_msg.payload[:session_id]).to eq("relay:5511999998888")
    end

    it "passes the event id through for dedup, and omits it when absent" do
      app = build_app(channels: registry_with(relay_channel))
      post(app, "/channels/relay/events", envelope(event_id: "wamid.1"))
      expect(bus.dispatched.last.payload[:event_id]).to eq("wamid.1")

      post(app, "/channels/relay/events", envelope)
      expect(bus.dispatched.last.payload).not_to have_key(:event_id)
    end

    it "does not create a session that already exists" do
      app = build_app(channels: registry_with(relay_channel),
                      session_store: ServerStoreDouble.new(Object.new))
      post(app, "/channels/relay/events", envelope)
      expect(bus.dispatched.map(&:type)).to eq([:send_message])
    end
  end

  # ACK FAST and never the reply: the consumer is holding a connection with a retry
  # timer on it. Nothing here subscribes to the turn.
  describe "the ack" do
    it "202s with the task that will answer" do
      app = build_app(channels: registry_with(relay_channel))
      status, _h, body = post(app, "/channels/relay/events", envelope)
      expect(status).to eq(202)
      expect(body_of(body)).to eq("task_id" => "t-1")
    end

    # RFC-0015 §5.5 + §6.4. Three different facts, and a consumer that reads any of
    # them as a 202 delivers the same answer twice.
    {
      merged: "it joined a turn still at the door",
      steered: "it was appended to a turn already running",
      duplicate: "the platform retried an event we already ran"
    }.each do |verdict, why|
      it "200s with #{verdict}: true when #{why}" do
        joined = ServerBusDouble.new do |c|
          c.type == :send_message ? { task_id: "t-owner", verdict => true } : {}
        end
        app = build_app(channels: registry_with(relay_channel), bus: joined)

        status, _h, body = post(app, "/channels/relay/events", envelope)
        expect(status).to eq(200)
        expect(body_of(body)).to eq("task_id" => "t-owner", verdict.to_s => true)
      end
    end
  end
end
