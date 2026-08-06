# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../server/app"

# Route contract from doc 07 §2-§6 with Rack::MockRequest + DOUBLE bus/stores
# (doc 07 §7, doubles in spec/support/server_doubles.rb). No real Executor/RubyLLM
# component is touched.
RSpec.describe Insika::Server::App do
  def event(type, data = {}, task_id: "t-1")
    Insika::Event.new(type: type, data: data, meta: { task_id: task_id })
  end

  def build_app(bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
                session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
                config: {}, a2a: nil, provisioner: nil, workflow_registry: nil, onboarding: nil,
                profiles: nil)
    described_class.new(
      command_bus: bus, event_stream: event_stream,
      session_store: session_store, task_store: task_store,
      a2a: a2a, provisioner: provisioner, workflow_registry: workflow_registry,
      onboarding: onboarding, profiles: profiles,
      config: { sync_timeout: 0.05, gateway_token: TOKEN }.merge(config)
    )
  end

  # Every route except the public allowlist needs the gateway Bearer, so the default
  # request carries it. `auth: nil` sends none (the gate's own cases); `auth: "x"` sends
  # a wrong one.
  TOKEN = "sekret"

  def call(app, method, path, body: nil, auth: TOKEN)
    opts = { method: method }
    opts[:input] = body if body
    env = Rack::MockRequest.env_for(path, opts)
    env["HTTP_AUTHORIZATION"] = "Bearer #{auth}" if auth
    app.call(env)
  end

  def json_body(resp) = JSON.parse(resp.join)

  # The gate lives in `route`, before the dispatch, as an ALLOWLIST of public routes.
  # It used to be each handler's job to call it, and the generic /v1/commands/:type
  # never did: every authoring Command (write_agent_file, upsert_llm_provider,
  # delete_agent…) was reachable by anyone who knew the URL, as were the session/task
  # reads. These cases are the guard for that class, not for one route.
  describe "the gateway gate (fail-closed by default)" do
    # Duck-typed stubs: the gate answers before any of them is touched.
    let(:registry) { Class.new { def catalog = [] }.new }
    let(:onboarding) do
      Class.new do
        def start_md(base_url:) = "# start #{base_url}"
        def models_json(base_url:) = { base_url: base_url }
        def docs_index(base_url:) = []
        def doc(_slug) = "# doc"
      end.new
    end

    it "refuses every mutating/reading v1 route without a Bearer" do
      bus = ServerBusDouble.new { { task_id: "t" } }
      app = build_app(bus: bus, workflow_registry: registry, provisioner: Object.new)
      [%w[POST /v1/commands/write_data_tool], %w[POST /v1/commands/delete_agent],
       %w[POST /v1/sessions], %w[POST /v1/messages], %w[POST /v1/responses],
       %w[POST /v1/tools/manifest], %w[POST /v1/agents], %w[POST /v1/workflows/flow],
       %w[GET /v1/workflows], %w[GET /v1/sessions/s-1], %w[GET /v1/tasks/t-1],
       %w[GET /v1/events]].each do |method, path|
        status, = call(app, method, path, body: "{}", auth: nil)
        expect(status).to eq(401), "expected 401 for #{method} #{path}, got #{status}"
      end
      expect(bus.dispatched).to be_empty # nothing reached the bus
    end

    it "refuses a wrong Bearer" do
      status, = call(build_app, "POST", "/v1/commands/write_data_tool", body: "{}", auth: "WRONG")
      expect(status).to eq(401)
    end

    it "is 503 (not open) when no token is configured at all" do
      app = build_app(config: { gateway_token: nil })
      status, = call(app, "POST", "/v1/commands/write_data_tool", body: "{}", auth: nil)
      expect(status).to eq(503)
    end

    it "keeps the public routes open: /up and the onboarding surface" do
      app = build_app(onboarding: onboarding, config: { gateway_token: nil })
      expect(call(app, "GET", "/up", auth: nil).first).to eq(200)
      expect(call(app, "GET", "/start.md", auth: nil).first).to eq(200)
      expect(call(app, "GET", "/models.json", auth: nil).first).to eq(200)
      expect(call(app, "GET", "/docs", auth: nil).first).to eq(200)
      expect(call(app, "GET", "/docs/TOOLS.md", auth: nil).first).to eq(200)
    end

    it "an unknown route answers the gate first (no route enumeration)" do
      expect(call(build_app, "GET", "/v1/whatever", auth: nil).first).to eq(401)
    end
  end

  describe "POST /v1/commands/:type (generic)" do
    it "translates body into Command(type, payload, transport: :http)" do
      bus = ServerBusDouble.new { |_c| { task_id: "t-9" } }
      app = build_app(bus: bus)

      call(app, "POST", "/v1/commands/cancel_task", body: '{"task_id":"t-9"}')

      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:cancel_task)
      expect(cmd.payload).to eq(task_id: "t-9")
      expect(cmd.meta[:transport]).to eq(:http)
    end

    it "control result (Data) -> 200 with to_h" do
      session = Insika::SessionStore::Session.new(
        id: "s-1", messages: [], vars: {}, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      app = build_app(bus: ServerBusDouble.new { session })

      status, _h, resp = call(app, "POST", "/v1/commands/create_session", body: "{}")

      expect(status).to eq(200)
      expect(json_body(resp)).to include("id" => "s-1")
    end

    it "turn result ({task_id:}) -> 202" do
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } })

      status, _h, resp = call(app, "POST", "/v1/commands/send_message", body: "{}")

      expect(status).to eq(202)
      expect(json_body(resp)).to eq("task_id" => "t-1")
    end
  end

  describe "A2A edge (P3A)" do
    let(:a2a) do
      Class.new do
        attr_reader :received
        def rpc(body) = (@received = body; { "jsonrpc" => "2.0", "id" => body["id"], "result" => { "ok" => true } })
        def agent_card = { "name" => "assistant", "url" => "u/a2a" }
      end.new
    end

    it "POST /a2a delegates to @a2a.rpc and responds 200 with the envelope" do
      app = build_app(a2a: a2a)
      status, _h, resp = call(app, "POST", "/a2a", body: '{"jsonrpc":"2.0","id":"1","method":"tasks/get"}')
      expect(status).to eq(200)
      expect(json_body(resp)).to include("result" => { "ok" => true })
      expect(a2a.received["method"]).to eq("tasks/get")
    end

    it "malformed JSON -> 200 with -32700 envelope (not an HTTP error)" do
      app = build_app(a2a: a2a)
      status, _h, resp = call(app, "POST", "/a2a", body: "{ not json")
      expect(status).to eq(200)
      expect(json_body(resp).dig("error", "code")).to eq(-32_700)
    end

    it "GET /.well-known/agent-card.json -> 200 with the card" do
      app = build_app(a2a: a2a)
      status, _h, resp = call(app, "GET", "/.well-known/agent-card.json")
      expect(status).to eq(200)
      expect(json_body(resp)).to include("name" => "assistant")
    end

    it "without @a2a (default): A2A routes -> 404 (parity)" do
      app = build_app # a2a: nil
      expect(call(app, "POST", "/a2a", body: "{}").first).to eq(404)
      expect(call(app, "GET", "/.well-known/agent-card.json").first).to eq(404)
    end

    it "empty body becomes payload {}" do
      bus = ServerBusDouble.new { { task_id: "t" } }
      app = build_app(bus: bus)

      call(app, "POST", "/v1/commands/send_message")

      expect(bus.dispatched.last.payload).to eq({})
    end
  end

  describe "POST /v1/sessions (sugar)" do
    it "dispatches :create_session and responds 201 {session}" do
      session = Insika::SessionStore::Session.new(
        id: "s-1", messages: [], vars: { "a" => 1 }, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new { session }
      app = build_app(bus: bus)

      status, _h, resp = call(app, "POST", "/v1/sessions", body: '{"vars":{"a":1}}')

      expect(bus.dispatched.last.type).to eq(:create_session)
      expect(bus.dispatched.last.payload).to eq(vars: { a: 1 })
      expect(status).to eq(201)
      expect(json_body(resp)["session"]).to include("id" => "s-1")
    end
  end

  describe "POST /v1/messages (sugar)" do
    it "dispatches :send_message with the translated payload (stream=false)" do
      bus = ServerBusDouble.new { { task_id: "t-1" } }
      stream = ServerEventStreamDouble.new([event(:task_completed, { content: "" })])
      app = build_app(bus: bus, event_stream: stream)

      call(app, "POST", "/v1/messages?stream=false",
           body: '{"agent":"sales","message":"oi"}')

      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:send_message)
      expect(cmd.payload).to eq(agent: "sales", message: "oi")
    end
  end

  describe "workflows exposed (item 22 / §4.4)" do
    # Read-only registry double: exposes a discovery catalog.
    def registry_double(catalog = [])
      Class.new do
        def initialize(catalog) = (@catalog = catalog)
        def catalog = @catalog
      end.new(catalog)
    end

    it "GET /v1/workflows returns the catalog (READ — no dispatch)" do
      cat = [{ "name" => "flow", "description" => "d", "input_schema" => { "type" => "object" }, "output_schema" => nil }]
      bus = ServerBusDouble.new
      app = build_app(bus: bus, workflow_registry: registry_double(cat))

      status, _h, resp = call(app, "GET", "/v1/workflows")

      expect(status).to eq(200)
      expect(json_body(resp)).to eq("workflows" => cat)
      expect(bus.dispatched).to be_empty
    end

    it "POST /v1/workflows/:name (async default) -> 202 {run_id, task_id} + dispatches :trigger_workflow from the route" do
      bus = ServerBusDouble.new { { task_id: "run-1", run_id: "run-1" } }
      app = build_app(bus: bus, workflow_registry: registry_double)

      status, _h, resp = call(app, "POST", "/v1/workflows/flow",
                              body: '{"agent":"sales","input":{"q":"x"},"session_id":"s-1"}')

      expect(status).to eq(202)
      expect(json_body(resp)).to eq("run_id" => "run-1", "task_id" => "run-1")
      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:trigger_workflow)
      expect(cmd.payload).to eq(workflow: "flow", agent: "sales", input: { q: "x" }, session_id: "s-1")
      expect(cmd.meta[:transport]).to eq(:http)
    end

    it "POST /v1/workflows/:name?stream=true -> 200 SSE body (streams the run)" do
      bus = ServerBusDouble.new { { task_id: "run-1", run_id: "run-1" } }
      stream = ServerEventStreamDouble.new([event(:task_completed, { content: "" }, task_id: "run-1")])
      app = build_app(bus: bus, event_stream: stream, workflow_registry: registry_double)

      status, headers, body = call(app, "POST", "/v1/workflows/flow?stream=true", body: '{"agent":"sales"}')

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(body).to be_a(Insika::Server::SSEBody)
    end

    it "workflows NOT exposed (registry nil) -> 404 on both routes (parity)" do
      app = build_app(workflow_registry: nil)
      expect(call(app, "GET", "/v1/workflows").first).to eq(404)
      expect(call(app, "POST", "/v1/workflows/flow", body: "{}").first).to eq(404)
    end
  end

  describe "reads (never Commands — D3)" do
    it "GET /v1/sessions/:id calls the store and does NOT dispatch" do
      session = Insika::SessionStore::Session.new(
        id: "s-1", messages: [], vars: {}, memory_refs: [],
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new
      app = build_app(bus: bus, session_store: ServerStoreDouble.new(session))

      status, _h, resp = call(app, "GET", "/v1/sessions/s-1")

      expect(status).to eq(200)
      expect(json_body(resp)["session"]).to include("id" => "s-1")
      expect(bus.dispatched).to be_empty
    end

    it "GET /v1/tasks/:id calls the store and does NOT dispatch" do
      task = Insika::TaskStore::Task.new(
        id: "t-1", status: :completed, command: {}, session_id: nil,
        executions: [], mailbox_state: {},
        created_at: "t", updated_at: "t"
      )
      bus = ServerBusDouble.new
      app = build_app(bus: bus, task_store: ServerStoreDouble.new(task))

      status, _h, resp = call(app, "GET", "/v1/tasks/t-1")

      expect(status).to eq(200)
      expect(json_body(resp)["task"]).to include("id" => "t-1", "status" => "completed")
      expect(bus.dispatched).to be_empty
    end

    it "GET /v1/tasks/:id serializes executions as readable JSON objects" do
      execution = Insika::TaskStore::Execution.new(
        attempt: 1, started_at: "a", finished_at: "b", outcome: "failed",
        error: { "class" => "Insika::ProviderError", "message" => "x" }
      )
      task = Insika::TaskStore::Task.new(
        id: "t-1", status: :failed, command: {}, session_id: nil,
        executions: [execution], mailbox_state: {}, created_at: "t", updated_at: "t"
      )
      app = build_app(task_store: ServerStoreDouble.new(task))

      _status, _h, resp = call(app, "GET", "/v1/tasks/t-1")

      exec = json_body(resp)["task"]["executions"].first
      expect(exec).to be_a(Hash) # not an opaque string "#<data ...>"
      expect(exec["outcome"]).to eq("failed")
      expect(exec["error"]).to eq("class" => "Insika::ProviderError", "message" => "x")
    end

    it "read of a non-existent session -> 404 with the standard error body" do
      app = build_app(session_store: ServerStoreDouble.new(nil))

      status, _h, resp = call(app, "GET", "/v1/sessions/nope")

      expect(status).to eq(404)
      expect(json_body(resp)["error"]["class"]).to eq("Insika::NotFoundError")
    end
  end

  describe "error->status mapping" do
    it "malformed JSON -> 400, zero dispatch" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)

      status, _h, resp = call(app, "POST", "/v1/commands/x", body: "{oops")

      expect(status).to eq(400)
      expect(json_body(resp)["error"]["class"]).to eq("JSON::ParserError")
      expect(bus.dispatched).to be_empty
    end

    it "ValidationError -> 422" do
      app = build_app(bus: ServerBusDouble.new { raise Insika::ValidationError, "ruim" })

      status, _h, resp = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(422)
      expect(json_body(resp)["error"]).to eq(
        "class" => "Insika::ValidationError", "message" => "ruim"
      )
    end

    it "NotFoundError -> 404" do
      app = build_app(bus: ServerBusDouble.new { raise Insika::NotFoundError, "sumiu" })

      status, = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(404)
    end

    it "generic StandardError -> 500" do
      app = build_app(bus: ServerBusDouble.new { raise "boom" })

      status, = call(app, "POST", "/v1/commands/x", body: "{}")

      expect(status).to eq(500)
    end

    it "synchronous dispatch timeout -> 504" do
      bus = ServerBusDouble.new { Async::Task.current.sleep(0.3) }
      app = build_app(bus: bus)

      status = nil
      Sync { status, = call(app, "POST", "/v1/commands/x", body: "{}") }

      expect(status).to eq(504)
    end

    it "no App path produces a 403 status" do
      source = File.read(File.expand_path("../../../server/app.rb", __dir__))
      expect(source).not_to match(/\b403\b/)
    end
  end

  describe "stream=false aggregates at the terminal" do
    it "accumulates :content deltas and responds at :task_completed" do
      events = [event(:content, { delta: "a" }), event(:content, { delta: "b" }),
                event(:task_completed, { content: "ab" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(status).to eq(200)
      expect(body["content"]).to eq("ab")
      expect(body["task_id"]).to eq("t-1")
      expect(body["events"].size).to eq(3)
    end

    it "responds with error: on :task_failed" do
      events = [event(:task_failed, { error: "Insika::ProviderError", message: "x" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(status).to eq(200)
      expect(body["error"]).to eq("class" => "Insika::ProviderError", "message" => "x")
    end

    it "reports :task_cancelled as error (never success)" do
      events = [event(:content, { delta: "parcial" }), event(:task_cancelled, { task_id: "t-1" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      _status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(body).not_to have_key("content")
      expect(body["error"]["class"]).to eq("Insika::CancelledError")
    end

    it "reports :error overflow as error (not a truncated 200 success)" do
      events = [event(:content, { delta: "a" }), event(:error, { message: "subscription overflow" })]
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } },
                      event_stream: ServerEventStreamDouble.new(events))

      _status, _h, resp = call(app, "POST", "/v1/messages?stream=false", body: "{}")

      body = json_body(resp)
      expect(body).not_to have_key("content")
      expect(body["error"]["message"]).to eq("subscription overflow")
    end
  end

  describe "SSE (stream=true default)" do
    it "responds 200 with SSE headers and an SSEBody body" do
      app = build_app(bus: ServerBusDouble.new { { task_id: "t-1" } })

      status, headers, body = call(app, "POST", "/v1/messages", body: "{}")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(headers["cache-control"]).to eq("no-cache")
      expect(headers["connection"]).to eq("keep-alive")
      expect(body).to be_a(Insika::Server::SSEBody)
    end

    it "GET /v1/events subscribes with the query filters and does NOT dispatch" do
      bus = ServerBusDouble.new
      stream = ServerEventStreamDouble.new
      app = build_app(bus: bus, event_stream: stream)

      status, _h, body = call(app, "GET", "/v1/events?task_id=t-1&session_id=s-2")

      expect(status).to eq(200)
      expect(body).to be_a(Insika::Server::SSEBody)
      expect(stream.subscribes.last).to eq(task_id: "t-1", session_id: "s-2")
      expect(bus.dispatched).to be_empty
    end
  end

  describe "POST /v1/responses (OpenAI Responses adapter — Phase 6)" do
    def responses_body(agent: "openclaw:bia", user: "chat-1", input: "oi")
      JSON.generate(model: agent, user: user, stream: true, input: input)
    end

    it "no gateway_token configured -> 503 fail-closed" do
      app = build_app(config: { gateway_token: nil })
      status, = call(app, "POST", "/v1/responses", body: responses_body)
      expect(status).to eq(503)
    end

    it "wrong token -> 401" do
      app = build_app(config: { gateway_token: "sekret" })
      env = Rack::MockRequest.env_for("/v1/responses", method: "POST", input: responses_body)
      env["HTTP_AUTHORIZATION"] = "Bearer WRONG"
      status, = app.call(env)
      expect(status).to eq(401)
    end

    it "token ok + new session: creates session (id=user) and dispatches send_message; returns SSEBody" do
      bus = ServerBusDouble.new { |c| c.type == :send_message ? { task_id: "t-1" } : {} }
      app = build_app(bus: bus, session_store: ServerStoreDouble.new(nil), config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/responses", method: "POST", input: responses_body(user: "chat-9", input: "olá"))
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, headers, body = app.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(body).to be_a(Insika::Server::SSEBody)

      create = bus.dispatched.find { |c| c.type == :create_session }
      expect(create.payload).to include(id: "chat-9")
      send = bus.dispatched.find { |c| c.type == :send_message }
      expect(send.payload).to include(agent: "bia", session_id: "chat-9", message: "olá")
    end

    it "existing session: does NOT create a session, only send_message" do
      record = { "id" => "chat-9" } # ServerStoreDouble#find returns truthy
      bus = ServerBusDouble.new { |c| c.type == :send_message ? { task_id: "t-1" } : {} }
      app = build_app(bus: bus, session_store: ServerStoreDouble.new(record), config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/responses", method: "POST", input: responses_body(user: "chat-9"))
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      app.call(env)

      expect(bus.dispatched.map(&:type)).to eq([:send_message])
    end

    it "invalid request (no user) -> 422" do
      app = build_app(config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/responses", method: "POST",
                                      input: JSON.generate(model: "openclaw:bia", input: "x"))
      env["HTTP_AUTHORIZATION"] = "Bearer tok"
      status, = app.call(env)
      expect(status).to eq(422)
    end
  end

  # RFC-0014 §3.2. The eval is a CLIENT — it never reads a store — so it needs one
  # gated read to tell "this case cannot run here" from "this case failed".
  describe "GET /v1/agents/:id (capability view)" do
    def profiles_with(profile)
      Insika::ProfileSource.coerce(profile.id => profile)
    end

    let(:profile) do
      Insika::AgentProfile.build(id: "ocean-drop", model: "m",
                                 tools_allow: %w[search_products search_orders],
                                 tools_deny: %w[search_orders],
                                 capabilities_declared: %w[promotions])
    end

    it "answers the two facts a case declares `requires` against" do
      status, _h, body = call(build_app(profiles: profiles_with(profile)), "GET", "/v1/agents/ocean-drop")

      expect(status).to eq(200)
      # deny wins, so a denied tool is NOT available — a case requiring it must skip.
      expect(json_body(body)).to eq("id" => "ocean-drop", "tools" => %w[search_products],
                                    "capabilities" => %w[promotions])
    end

    it "reports an OPEN allowlist as null, not as an empty set" do
      open = Insika::AgentProfile.build(id: "bia", model: "m")

      _s, _h, body = call(build_app(profiles: profiles_with(open)), "GET", "/v1/agents/bia")

      # [] would mean "has no tools" and would skip every case; null means "every
      # registered tool", which the client reads as "cannot rule anything out".
      expect(json_body(body)["tools"]).to be_nil
    end

    it "never leaks the profile — no prompt, no model, no guardrail config" do
      full = Insika::AgentProfile.build(id: "bia", model: "secret-model", base_prompt: "SOUL",
                                        guardrails: { "output" => true })

      _s, _h, body = call(build_app(profiles: profiles_with(full)), "GET", "/v1/agents/bia")

      expect(json_body(body).keys).to contain_exactly("id", "tools", "capabilities")
    end

    it "unknown agent -> 404" do
      status, = call(build_app(profiles: profiles_with(profile)), "GET", "/v1/agents/nope")
      expect(status).to eq(404)
    end

    it "not wired -> 404 (parity)" do
      status, = call(build_app, "GET", "/v1/agents/ocean-drop")
      expect(status).to eq(404)
    end

    it "is behind the gateway Bearer like every other /v1 read" do
      status, = call(build_app(profiles: profiles_with(profile)), "GET", "/v1/agents/ocean-drop", auth: nil)
      expect(status).to eq(401)
    end
  end

  describe "provisioning POST/DELETE /v1/agents (Phase 6/D4/F7)" do
    # double provisioner: records the imported pack / the deleted id.
    class ProvisionerDouble
      attr_reader :imported, :deleted

      def import(pack) = (@imported = pack; { agent_id: pack.config[:id], created: true })
      def delete(id) = (@deleted = id; { agent_id: id, deleted: true })
    end

    def pack_body(id: "loja-7")
      JSON.generate(config: { id: id, model: "m" },
                    files: { "IDENTITY.md" => "quem sou" },
                    skills: {}, tools: [])
    end

    it "not exposed when provisioner nil -> 404" do
      status, = call(build_app, "POST", "/v1/agents", body: pack_body)
      expect(status).to eq(404)
    end

    it "no gateway_token configured -> 503 fail-closed" do
      app = build_app(provisioner: ProvisionerDouble.new, config: { gateway_token: nil })
      status, = call(app, "POST", "/v1/agents", body: pack_body)
      expect(status).to eq(503)
    end

    it "wrong token -> 401" do
      app = build_app(provisioner: ProvisionerDouble.new, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/agents", method: "POST", input: pack_body)
      env["HTTP_AUTHORIZATION"] = "Bearer WRONG"
      status, = app.call(env)
      expect(status).to eq(401)
    end

    it "token ok: builds the Pack (file keys preserved) and imports -> 200" do
      prov = ProvisionerDouble.new
      app = build_app(provisioner: prov, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/agents", method: "POST", input: pack_body(id: "loja-9"))
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, _h, resp = app.call(env)

      expect(status).to eq(200)
      expect(json_body(resp)).to eq("agent_id" => "loja-9", "created" => true)
      expect(prov.imported).to be_a(Insika::Pack)
      expect(prov.imported.config).to eq(id: "loja-9", model: "m")
      expect(prov.imported.files).to eq("IDENTITY.md" => "quem sou") # key did NOT become a symbol
    end

    it "DELETE /v1/agents/:id -> delete via provisioner (200)" do
      prov = ProvisionerDouble.new
      app = build_app(provisioner: prov, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/agents/loja-7", method: "DELETE")
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, _h, resp = app.call(env)

      expect(status).to eq(200)
      expect(prov.deleted).to eq("loja-7")
      expect(json_body(resp)).to eq("agent_id" => "loja-7", "deleted" => true)
    end

    it "import validation error -> 422 (via #call rescue)" do
      prov = ProvisionerDouble.new
      def prov.import(_p) = raise(Insika::ValidationError, "pack sem config.id")
      app = build_app(provisioner: prov, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/agents", method: "POST", input: pack_body)
      env["HTTP_AUTHORIZATION"] = "Bearer tok"
      status, = app.call(env)
      expect(status).to eq(422)
    end
  end

  describe "manifest ingestion POST /v1/tools/manifest (Phase 7, Stage B)" do
    def manifest_body
      JSON.generate(version: 1,
                    defaults: { "base_url" => "https://api.test", "path_template" => "/{endpoint}" },
                    tools: [{ "name" => "search_products", "endpoint" => "search_products",
                              "parameters" => { "type" => "object",
                                                "properties" => { "q" => { "type" => "string" } },
                                                "required" => ["q"] } }])
    end

    it "no gateway_token configured -> 503 fail-closed" do
      status, = call(build_app(config: { gateway_token: nil }), "POST", "/v1/tools/manifest", body: manifest_body)
      expect(status).to eq(503)
    end

    it "wrong token -> 401" do
      app = build_app(config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/tools/manifest", method: "POST", input: manifest_body)
      env["HTTP_AUTHORIZATION"] = "Bearer WRONG"
      status, = app.call(env)
      expect(status).to eq(401)
    end

    it "token ok: dispatches :import_tools with the RAW manifest (string keys) -> 200 report" do
      bus = ServerBusDouble.new { |_c| { version: 1, created: ["search_products"], updated: [], errors: [] } }
      app = build_app(bus: bus, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/tools/manifest", method: "POST", input: manifest_body)
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, _h, resp = app.call(env)

      expect(status).to eq(200)
      expect(json_body(resp)).to eq("version" => 1, "created" => ["search_products"], "updated" => [], "errors" => [])
      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:import_tools)
      # JSON Schema property names preserved as STRING (not symbolized)
      expect(cmd.payload["tools"].first["parameters"]["properties"]).to have_key("q")
      expect(cmd.meta[:transport]).to eq(:http)
    end

    it "manifest structural error -> 422 (via #call rescue)" do
      bus = ServerBusDouble.new { |_c| raise(Insika::ValidationError, "manifest: 'tools' must be a list") }
      app = build_app(bus: bus, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/tools/manifest", method: "POST", input: manifest_body)
      env["HTTP_AUTHORIZATION"] = "Bearer tok"
      status, = app.call(env)
      expect(status).to eq(422)
    end
  end

  describe "live MCP ingestion POST /v1/mcp/:name/import (Phase 7, Stage E)" do
    it "no gateway_token configured -> 503 fail-closed" do
      status, = call(build_app(config: { gateway_token: nil }), "POST", "/v1/mcp/tavily/import")
      expect(status).to eq(503)
    end

    it "wrong token -> 401" do
      app = build_app(config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/mcp/tavily/import", method: "POST")
      env["HTTP_AUTHORIZATION"] = "Bearer WRONG"
      status, = app.call(env)
      expect(status).to eq(401)
    end

    it "token ok: dispatches :import_mcp_tools with the ROUTE name -> 200 report" do
      bus = ServerBusDouble.new { |_c| { instance: "tavily", version: 1, created: ["search"], updated: [], errors: [] } }
      app = build_app(bus: bus, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/mcp/tavily/import", method: "POST")
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, _h, resp = app.call(env)

      expect(status).to eq(200)
      expect(json_body(resp)).to include("instance" => "tavily", "created" => ["search"])
      cmd = bus.dispatched.last
      expect(cmd.type).to eq(:import_mcp_tools)
      expect(cmd.payload).to eq(name: "tavily")
      expect(cmd.meta[:transport]).to eq(:http)
    end

    it "non-existent instance (NotFoundError from the handler) -> 404" do
      bus = ServerBusDouble.new { |_c| raise(Insika::NotFoundError, "instância MCP 'x' not found") }
      app = build_app(bus: bus, config: { gateway_token: "tok" })
      env = Rack::MockRequest.env_for("/v1/mcp/x/import", method: "POST")
      env["HTTP_AUTHORIZATION"] = "Bearer tok"
      status, = app.call(env)
      expect(status).to eq(404)
    end
  end

  describe "health check GET /up" do
    it "200 {status:ok} without auth and without touching the store" do
      status, headers, resp = call(build_app, "GET", "/up")
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(json_body(resp)).to eq("status" => "ok")
    end
  end

  describe "onboarding surface (item 20 / §5.6)" do
    # Duck-typed double: the app only calls these four reads.
    let(:onboarding) do
      Class.new do
        attr_reader :seen_base
        def start_md(base_url:) = (@seen_base = base_url; "# start (#{base_url})")
        def models_json(base_url:) = { base_url: base_url, thinking_levels: %w[off on] }
        def docs_index(base_url:) = [{ name: "readme", url: "#{base_url}/docs/readme.md" }]
        def doc(slug) = (slug == "readme" ? "# Insika readme" : nil)
      end.new
    end

    it "GET /start.md -> 200 raw markdown, base url from the request" do
      app = build_app(onboarding: onboarding)
      status, headers, resp = call(app, "GET", "/start.md")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/markdown; charset=utf-8")
      expect(resp.join).to eq("# start (http://example.org)")
      expect(onboarding.seen_base).to eq("http://example.org")
    end

    it "GET /models.json -> 200 application/json" do
      app = build_app(onboarding: onboarding)
      status, headers, resp = call(app, "GET", "/models.json")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(json_body(resp)).to include("thinking_levels" => %w[off on])
    end

    it "GET /docs -> 200 with the doc index" do
      status, _h, resp = call(build_app(onboarding: onboarding), "GET", "/docs")
      expect(status).to eq(200)
      expect(json_body(resp)["docs"].first).to include("name" => "readme")
    end

    it "GET /docs/:name.md -> 200 raw markdown for a known doc" do
      status, headers, resp = call(build_app(onboarding: onboarding), "GET", "/docs/readme.md")

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/markdown; charset=utf-8")
      expect(resp.join).to eq("# Insika readme")
    end

    it "GET /docs/:name.md -> 404 for an unknown doc" do
      status, = call(build_app(onboarding: onboarding), "GET", "/docs/missing.md")
      expect(status).to eq(404)
    end

    it "GET /docs/:name (no .md) is not an onboarding route -> 404" do
      status, = call(build_app(onboarding: onboarding), "GET", "/docs/readme")
      expect(status).to eq(404)
    end

    it "config[:public_url] overrides the request base (behind a TLS proxy)" do
      app = build_app(onboarding: onboarding, config: { public_url: "https://insika.example" })
      call(app, "GET", "/start.md")
      expect(onboarding.seen_base).to eq("https://insika.example")
    end

    it "the routes are OPT-IN: with no onboarding injected they 404 (parity)" do
      app = build_app # onboarding: nil
      expect(call(app, "GET", "/start.md").first).to eq(404)
      expect(call(app, "GET", "/models.json").first).to eq(404)
      expect(call(app, "GET", "/docs").first).to eq(404)
      expect(call(app, "GET", "/docs/readme.md").first).to eq(404)
    end

    it "the surface is PUBLIC — no bearer required (like /up)" do
      app = build_app(onboarding: onboarding, config: { gateway_token: "secret" })
      expect(call(app, "GET", "/start.md").first).to eq(200)
      expect(call(app, "GET", "/models.json").first).to eq(200)
    end
  end

  describe "unknown route" do
    it "GET /nada -> 404 not found (text/plain)" do
      status, headers, resp = call(build_app, "GET", "/nada")

      expect(status).to eq(404)
      expect(headers["content-type"]).to eq("text/plain")
      expect(resp.join).to eq("not found")
    end

    it "/admin (retired) -> 404 like any other unknown route" do
      status, = call(build_app, "GET", "/admin")
      expect(status).to eq(404)
    end

    it "wrong method on a known route -> 404" do
      status, = call(build_app, "PUT", "/v1/commands/x")
      expect(status).to eq(404)
    end
  end
end
