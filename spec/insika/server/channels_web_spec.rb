# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/app"

# RFC-0011 §4.4 / §5 — the Shape A half of the channel mount: mint, turn, asset,
# preflight. The cases worth writing are the ones where being wrong is a security
# hole (a session someone else can use, a route that answers without the channel's
# own check) rather than a cosmetic bug.
RSpec.describe "Insika::Server::App channels (Shape A)" do
  WEB_GATEWAY_TOKEN = "gw-token"
  WEB_ORIGIN = "https://shop.example"

  let(:bus) { ServerBusDouble.new { |_c| { task_id: "t-1" } } }

  Session = Struct.new(:id, :vars)

  def web_channel(**over)
    Insika::Channels::Web.new(**{ origins: [WEB_ORIGIN], agents: %w[support],
                                  chat_rate_limit: ->(_a) { 6 } }.merge(over))
  end

  def registry_with(channel, id: "web")
    Insika::ChannelRegistry.new.tap { |r| r.register(id, channel) }
  end

  def build_app(channels:, bus: self.bus, session: Session.new("web:abc", { "channel" => "web" }))
    Insika::Server::App.new(
      command_bus: bus, event_stream: ServerEventStreamDouble.new,
      session_store: ServerStoreDouble.new(session), task_store: ServerStoreDouble.new(nil),
      channels: channels, config: { sync_timeout: 0.05, gateway_token: WEB_GATEWAY_TOKEN }
    )
  end

  def call(app, path, method: "POST", body: nil, origin: WEB_ORIGIN)
    env = Rack::MockRequest.env_for(path, method: method, input: body)
    env["HTTP_ORIGIN"] = origin if origin
    app.call(env)
  end

  def message(**over)
    JSON.generate({ "agent" => "support", "session_id" => "web:abc", "message" => "oi" }
                    .merge(over.transform_keys(&:to_s)))
  end

  def body_of(resp) = JSON.parse(resp.join)

  describe "POST /channels/:id/sessions" do
    it "mints an opaque id the engine owns and creates the session" do
      app = build_app(channels: registry_with(web_channel), session: nil)
      status, _h, body = call(app, "/channels/web/sessions")

      expect(status).to eq(201)
      minted = body_of(body)["session_id"]
      expect(minted).to start_with("web:")

      create = bus.dispatched.find { |c| c.type == :create_session }
      expect(create.payload[:id]).to eq(minted)
      expect(create.payload[:vars]).to eq("channel" => "web")
    end

    it "answers with the CORS headers, or the browser cannot read the id it just got" do
      app = build_app(channels: registry_with(web_channel), session: nil)
      _s, headers, = call(app, "/channels/web/sessions")
      expect(headers["access-control-allow-origin"]).to eq(WEB_ORIGIN)
    end

    # The relay's id is the consumer's own key — there is nothing to mint, so the
    # route does not exist for it (parity, like every other optional surface).
    it "404s for a channel that does not mint" do
      relay = Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h")
      app = build_app(channels: registry_with(relay, id: "relay"))
      expect(call(app, "/channels/relay/sessions").first).to eq(404)
    end

    it "503s before minting anything when no rate limit is configured" do
      app = build_app(channels: registry_with(web_channel(chat_rate_limit: nil)), session: nil)
      expect(call(app, "/channels/web/sessions").first).to eq(503)
      expect(bus.dispatched).to be_empty
    end
  end

  describe "POST /channels/:id/messages" do
    it "runs the turn on this connection, tagged with the channel transport" do
      app = build_app(channels: registry_with(web_channel))
      status, headers, body = call(app, "/channels/web/messages", body: message)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(headers["access-control-allow-origin"]).to eq(WEB_ORIGIN)
      expect(body).to be_a(Insika::Server::SSEBody)

      sent = bus.dispatched.find { |c| c.type == :send_message }
      expect(sent.meta[:transport]).to eq(:"channel:web")
      expect(sent.payload).to include(agent: "support", session_id: "web:abc", message: "oi")
    end

    # §4.3: never create-on-write for a public channel — that is the enumeration
    # hole `/sessions` exists to close, reopened.
    it "404s an unknown session and creates nothing" do
      app = build_app(channels: registry_with(web_channel), session: nil)
      expect(call(app, "/channels/web/messages", body: message).first).to eq(404)
      expect(bus.dispatched).to be_empty
    end

    # A widget visitor must not be able to stream a relay customer's conversation by
    # pasting its session id.
    it "404s a session that belongs to another channel" do
      app = build_app(channels: registry_with(web_channel),
                      session: Session.new("relay:5511", { "channel" => "relay" }))
      expect(call(app, "/channels/web/messages", body: message(session_id: "relay:5511")).first).to eq(404)
      expect(bus.dispatched).to be_empty
    end

    it "422s an agent the operator did not publish, with the CORS headers on it" do
      app = build_app(channels: registry_with(web_channel))
      status, headers, body = call(app, "/channels/web/messages", body: message(agent: "internal-admin"))

      expect(status).to eq(422)
      expect(headers["access-control-allow-origin"]).to eq(WEB_ORIGIN)
      expect(body_of(body).dig("error", "message")).to match(/not published/)
      expect(bus.dispatched).to be_empty
    end

    it "401s an origin nobody allowlisted, before the turn" do
      app = build_app(channels: registry_with(web_channel))
      expect(call(app, "/channels/web/messages", body: message, origin: "https://evil.example").first).to eq(401)
      expect(bus.dispatched).to be_empty
    end

    it "503s when the rate limit went away, rather than serving an unmetered turn" do
      app = build_app(channels: registry_with(web_channel(chat_rate_limit: ->(_a) { 0 })))
      expect(call(app, "/channels/web/messages", body: message).first).to eq(503)
      expect(bus.dispatched).to be_empty
    end
  end

  describe "GET /channels/:id/asset/:f" do
    it "serves the widget with a cache policy and an etag" do
      app = build_app(channels: registry_with(web_channel))
      status, headers, body = call(app, "/channels/web/asset/widget.js", method: "GET")

      expect(status).to eq(200)
      expect(headers["content-type"]).to start_with("application/javascript")
      expect(headers["etag"]).to match(/\A"[0-9a-f]+"\z/)
      expect(body.join).to include("insika")
    end

    it "304s a browser that already has this exact widget" do
      app = build_app(channels: registry_with(web_channel))
      _s, headers, = call(app, "/channels/web/asset/widget.js", method: "GET")

      env = Rack::MockRequest.env_for("/channels/web/asset/widget.js", method: "GET")
      env["HTTP_IF_NONE_MATCH"] = headers["etag"]
      status, _h, body = app.call(env)
      expect(status).to eq(304)
      expect(body.to_a).to be_empty
    end

    it "404s an unknown file and a traversal attempt" do
      app = build_app(channels: registry_with(web_channel))
      expect(call(app, "/channels/web/asset/nope.js", method: "GET").first).to eq(404)
      expect(call(app, "/channels/web/asset/..%2F..%2Fetc%2Fpasswd", method: "GET").first).to eq(404)
    end

    it "404s for a channel with no assets" do
      relay = Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h")
      app = build_app(channels: registry_with(relay, id: "relay"))
      expect(call(app, "/channels/relay/asset/widget.js", method: "GET").first).to eq(404)
    end
  end

  # A preflight carries no credentials by spec, so gating it would only mean the
  # real request never happens. It grants nothing: a stranger's origin gets no
  # headers back and the browser refuses the response itself.
  describe "OPTIONS /channels/:id/*" do
    it "204s with the CORS headers for an allowlisted origin" do
      app = build_app(channels: registry_with(web_channel))
      status, headers, = call(app, "/channels/web/messages", method: "OPTIONS")

      expect(status).to eq(204)
      expect(headers["access-control-allow-origin"]).to eq(WEB_ORIGIN)
      expect(headers["access-control-allow-headers"]).to include("content-type")
    end

    it "grants no headers to an origin nobody allowlisted" do
      app = build_app(channels: registry_with(web_channel))
      _s, headers, = call(app, "/channels/web/messages", method: "OPTIONS", origin: "https://evil.example")
      expect(headers).not_to have_key("access-control-allow-origin")
    end

    it "404s for a channel nobody registered" do
      app = build_app(channels: Insika::ChannelRegistry.new)
      expect(call(app, "/channels/web/messages", method: "OPTIONS").first).to eq(404)
    end
  end

  # The whole family skips the GATEWAY bearer because the channel carries its own
  # check. That is only safe if every route actually runs it.
  describe "the gateway bearer" do
    it "is not required on any Shape A route" do
      app = build_app(channels: registry_with(web_channel), session: nil)
      expect(call(app, "/channels/web/sessions").first).to eq(201)
      expect(call(app, "/channels/web/asset/widget.js", method: "GET").first).to eq(200)
    end

    it "does not stand in for the channel's own check" do
      app = build_app(channels: registry_with(web_channel(chat_rate_limit: nil)), session: nil)
      env = Rack::MockRequest.env_for("/channels/web/sessions", method: "POST")
      env["HTTP_AUTHORIZATION"] = "Bearer #{WEB_GATEWAY_TOKEN}"
      expect(app.call(env).first).to eq(503)
    end
  end

  it "404s the Shape A routes when the deployment registers no channels" do
    app = build_app(channels: Insika::ChannelRegistry.new)
    expect(call(app, "/channels/web/sessions").first).to eq(404)
    expect(call(app, "/channels/web/messages", body: message).first).to eq(404)
  end
end
