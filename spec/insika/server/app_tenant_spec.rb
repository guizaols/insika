# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../lib/insika/server/app"
require_relative "../../support/server_doubles"

# WS1 acceptance: two tenants on ONE deployment — per-tenant resolution,
# isolated sessions/tasks/memory, operator surfaces refused to tenants, and a
# revoked token killing exactly one tenant.
RSpec.describe Insika::Server::App do
  # Helper methods of the example group CAN see the `let`s — the bare
  # `token_store` below is the let, not a parameter.
  def build_tenant_app(bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
                       session_store: ServerStoreDouble.new(nil),
                       task_store: ServerStoreDouble.new(nil),
                       logger: nil)
    described_class.new(
      command_bus: bus, event_stream: event_stream,
      session_store: session_store, task_store: task_store,
      token_store: token_store,
      config: { sync_timeout: 0.05, gateway_token: "op-sekret", tenancy: "multi_tenant" },
      logger: logger
    )
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:token_store) { Insika::TokenStore.new(store: backend) }
  let!(:tenant_a) { token_store.issue(tenant_id: "loja-a") }
  let!(:tenant_b) { token_store.issue(tenant_id: "loja-b") }

  def call(app, method, path, body: nil, auth: nil)
    opts = { method: method }
    opts[:input] = body if body
    env = Rack::MockRequest.env_for(path, opts)
    env["HTTP_AUTHORIZATION"] = "Bearer #{auth}" if auth
    app.call(env)
  end

  def json_body(resp) = JSON.parse(resp.join)

  describe "the gateway gate in multi_tenant mode" do
    it "resolves a tenant token to its own principal; tenant surfaces work, operator surfaces are 403" do
      bus = ServerBusDouble.new
      app = build_tenant_app(bus: bus)

      # a tenant CAN chat...
      status, = call(app, "POST", "/v1/messages?stream=false",
                    body: JSON.generate(message: "oi", session_id: "chat-1"), auth: tenant_a.token)
      expect(status).to eq(200)

      # ...but CANNOT reach the command gate (authoring/config/tokens are the
      # operator's) — refused with 403, not 404 (the route exists).
      status2, = call(app, "POST", "/v1/commands/issue_tenant_token",
                     body: JSON.generate(tenant_id: "loja-a"), auth: tenant_a.token)
      expect(status2).to eq(403)
      status3, = call(app, "POST", "/v1/agents", body: "{}", auth: tenant_a.token)
      expect(status3).to eq(403)
    end

    it "a revoked token 401s for ITS tenant only; the other tenant keeps working" do
      bus = ServerBusDouble.new
      app = build_tenant_app(bus: bus)
      token_store.revoke(tenant_a.id)

      status_a, = call(app, "POST", "/v1/messages?stream=false",
                      body: JSON.generate(message: "oi", session_id: "chat-1"), auth: tenant_a.token)
      expect(status_a).to eq(401)

      status_b, = call(app, "POST", "/v1/messages?stream=false",
                      body: JSON.generate(message: "oi", session_id: "chat-1"),
                      auth: tenant_b.token)
      expect(status_b).to eq(200)
      expect(bus.dispatched.any? { |c| c.type == :send_message }).to be(true)
    end

    it "the legacy OPERATOR token still resolves in multi_tenant (mode-switch compat)" do
      bus = Insika::CommandBus.new
      bus.register(:issue_tenant_token,
                   Insika::Commands::IssueTenantToken.new(token_store: token_store,
                                                          event_stream: Insika::EventStream.new))
      app = build_tenant_app(bus: bus)

      status, _h, resp = call(app, "POST", "/v1/commands/issue_tenant_token",
                             body: JSON.generate(tenant_id: "loja-c"), auth: "op-sekret")

      expect(status).to eq(200)
      expect(json_body(resp).keys).to include("token", "id")
      expect(token_store.resolve(json_body(resp)["token"]).tenant_id).to eq("loja-c")
    end
  end

  describe "tenant scoping of the runtime surfaces" do
    it "two tenants using the SAME chat id get isolated sessions and stamped commands" do
      bus = ServerBusDouble.new
      app = build_tenant_app(bus: bus)

      call(app, "POST", "/v1/messages?stream=false",
           body: JSON.generate(message: "oi", session_id: "chat-1"), auth: tenant_a.token)
      call(app, "POST", "/v1/messages?stream=false",
           body: JSON.generate(message: "oi", session_id: "chat-1"), auth: tenant_b.token)

      sends = bus.dispatched.select { |c| c.type == :send_message }

      # the session keys are NAMESPACED — the isolation is the key itself, so
      # tenant B can never land in tenant A's session even with the same chat id.
      expect(sends.map { |c| c.payload[:session_id] }).to eq(["loja-a:chat-1", "loja-b:chat-1"])
      # and the executor's memory/state scoping receives the tenant.
      expect(sends.map { |c| c.meta[:tenant] }).to eq(["loja-a", "loja-b"])
    end

    it "/v1/responses namespaces the session the same way (create_session included)" do
      bus = ServerBusDouble.new
      app = build_tenant_app(bus: bus)
      body = JSON.generate(model: "bia", user: "chat-1", stream: true, input: "oi")

      call(app, "POST", "/v1/responses", body: body, auth: tenant_a.token)

      send = bus.dispatched.find { |c| c.type == :send_message }
      create = bus.dispatched.find { |c| c.type == :create_session }
      expect(send.payload[:session_id]).to eq("loja-a:chat-1")
      expect(send.meta[:tenant]).to eq("loja-a")
      expect(create.payload[:id]).to eq("loja-a:chat-1")
      expect(create.meta[:tenant]).to eq("loja-a")
    end

    it "GET /v1/sessions/:id — a tenant reads only its OWN session (the namespace IS the ownership)" do
      session = Insika::SessionStore::Session.new(
        id: "loja-a:chat-1", messages: [], vars: {}, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      app = build_tenant_app(session_store: ServerStoreDouble.new(session))

      own = call(app, "GET", "/v1/sessions/loja-a:chat-1", auth: tenant_a.token)
      expect(own[0]).to eq(200)

      other = call(app, "GET", "/v1/sessions/loja-a:chat-1", auth: tenant_b.token)
      expect(other[0]).to eq(404) # exists — but NOT theirs

      stranger = call(app, "GET", "/v1/sessions/whatever", auth: tenant_a.token)
      expect(stranger[0]).to eq(404)
    end

    it "POST /v1/sessions — a tenant's session is born INSIDE its own namespace (read-back-guaranteed)" do
      bus = ServerBusDouble.new
      app = build_tenant_app(bus: bus)

      call(app, "POST", "/v1/sessions", body: JSON.generate(id: "chat-1"), auth: tenant_a.token)
      call(app, "POST", "/v1/sessions", body: JSON.generate(vars: { "a" => 1 }), auth: tenant_a.token)
      call(app, "POST", "/v1/sessions", body: JSON.generate(id: "loja-a:chat-2"), auth: tenant_a.token)

      creates = bus.dispatched.select { |c| c.type == :create_session }
      expect(creates.map { |c| c.meta[:tenant] }).to all(eq("loja-a"))
      expect(creates[0].payload[:id]).to eq("loja-a:chat-1")            # caller id scoped
      expect(creates[2].payload[:id]).to eq("loja-a:chat-2")            # idempotent, no double prefix
      expect(creates[1].payload[:id]).to match(/\Aloja-a:[0-9a-f-]+\z/) # no id -> a namespaced uuid
    end

    it "GET /v1/tasks/:id — a tenant reads only tasks its own command stamped" do
      task = Insika::TaskStore::Task.new(
        id: "t-1", status: :failed, session_id: "loja-a:chat-1",
        command: { "type" => "send_message", "payload" => {}, "meta" => { "tenant" => "loja-a" } },
        executions: [], mailbox_state: {}, timing: nil, created_at: "t", updated_at: "t"
      )
      app = build_tenant_app(task_store: ServerStoreDouble.new(task))

      own = call(app, "GET", "/v1/tasks/t-1", auth: tenant_a.token)
      expect(own[0]).to eq(200)

      other = call(app, "GET", "/v1/tasks/t-1", auth: tenant_b.token)
      expect(other[0]).to eq(404) # exists — but NOT theirs

      # the OPERATOR reads everything (the operator is not a tenant).
      op = call(app, "GET", "/v1/tasks/t-1", auth: "op-sekret")
      expect(op[0]).to eq(200)
    end

    it "GET /v1/events — a tenant's stream is scoped to its own events" do
      bus = ServerBusDouble.new
      stream = ServerEventStreamDouble.new
      app = build_tenant_app(bus: bus, event_stream: stream)

      call(app, "GET", "/v1/events?session_id=x", auth: tenant_a.token)
      call(app, "GET", "/v1/events?session_id=x", auth: "op-sekret")

      expect(stream.subscribes[0][:tenant]).to eq("loja-a")
      expect(stream.subscribes[1][:tenant]).to be_nil # operator sees all
    end
  end

  describe "single_tenant mode is untouched (parity)" do
    it "the classic app (no store) still accepts the gateway token for everything" do
      bus = ServerBusDouble.new
      app = described_class.new(
        command_bus: bus, event_stream: ServerEventStreamDouble.new,
        session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
        config: { sync_timeout: 0.05, gateway_token: "sekret" }
      )

      status, = call(app, "POST", "/v1/commands/issue_tenant_token",
                    body: JSON.generate(tenant_id: "loja-a"), auth: "sekret")
      expect(status).to eq(200)

      status2, = call(app, "POST", "/v1/messages?stream=false",
                     body: JSON.generate(message: "oi", session_id: "chat-1"), auth: "sekret")
      expect(status2).to eq(200)
      expect(bus.dispatched.first.meta[:tenant]).to be_nil # no tenant stamping
    end
  end
end