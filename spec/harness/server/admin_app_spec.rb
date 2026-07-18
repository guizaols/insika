# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/app"

# /admin read-only through Server::App (auth + CORS + delegation exercised
# together). Double stores/catalogs/registries; correct token in the header.
RSpec.describe Harness::Server::Admin::App do
  # --- Read doubles -------------------------------------------------
  AdminStore = Struct.new(:records) do
    def each_id(&blk) = records.keys.each(&blk)
    def find(id) = records[id]
  end

  CheckpointDouble = Struct.new(:by_task) do
    def latest(task_id) = by_task[task_id]
  end

  CatalogDouble = Struct.new(:items) do
    def all = items
  end

  RegistryDouble = Struct.new(:list) do
    def entries = list
  end

  def session(id, messages: [], vars: {})
    Harness::SessionStore::Session.new(
      id: id, messages: messages, vars: vars, memory_refs: [],
      created_at: "c", updated_at: "u"
    )
  end

  def task(id, status: :completed, executions: [], session_id: nil)
    Harness::TaskStore::Task.new(
      id: id, status: status, command: { "type" => "send_message" }, session_id: session_id,
      executions: executions, mailbox_state: {},
      created_at: "c", updated_at: "u"
    )
  end

  def build_app(sessions: {}, tasks: {}, checkpoints: {}, skills: [],
                tools: [], workflows: [], admin_token: "s3cret", allowed_origins: [],
                bus: ServerBusDouble.new)
    Harness::Server::App.new(
      command_bus: bus, event_stream: ServerEventStreamDouble.new,
      session_store: AdminStore.new(sessions), task_store: AdminStore.new(tasks),
      checkpoint_store: CheckpointDouble.new(checkpoints),
      catalogs: { skills: CatalogDouble.new(skills) },
      registries: { tools: RegistryDouble.new(tools), workflows: RegistryDouble.new(workflows) },
      config: { admin_token: admin_token, allowed_origins: allowed_origins }
    )
  end

  def call(app, method, path, auth: "Bearer s3cret", origin: nil)
    env = Rack::MockRequest.env_for(path, method: method)
    env["HTTP_AUTHORIZATION"] = auth if auth
    env["HTTP_ORIGIN"] = origin if origin
    app.call(env)
  end

  def body_of(resp) = resp.join

  describe "auth -> HTTP (doc 07 §6)" do
    it "no token configured -> 503 admin disabled" do
      status, _h, resp = call(build_app(admin_token: nil), "GET", "/admin")
      expect(status).to eq(503)
      expect(JSON.parse(body_of(resp))["error"]).to eq(
        "class" => "Harness::Error", "message" => "admin disabled"
      )
    end

    it "wrong token -> 401 + www-authenticate" do
      status, headers, = call(build_app, "GET", "/admin", auth: "Bearer nope")
      expect(status).to eq(401)
      expect(headers["www-authenticate"]).to eq("Bearer")
    end

    it "correct token -> 200" do
      status, = call(build_app, "GET", "/admin")
      expect(status).to eq(200)
    end
  end

  describe "render read-only" do
    it "index lists the 5 sections" do
      _s, headers, resp = call(build_app, "GET", "/admin")
      html = body_of(resp)
      expect(headers["content-type"]).to eq("text/html; charset=utf-8")
      %w[/admin/sessions /admin/tasks /admin/events /admin/skills /admin/plugins].each do |href|
        expect(html).to include(href)
      end
    end

    it "sends security headers (CSP + nosniff) on the pages" do
      _s, headers, = call(build_app, "GET", "/admin")
      expect(headers["x-content-type-options"]).to eq("nosniff")
      expect(headers["content-security-policy"]).to include("default-src 'none'", "connect-src 'self'")
    end

    it "lists sessions with ids" do
      app = build_app(sessions: { "s-1" => session("s-1"), "s-2" => session("s-2") })
      _s, _h, resp = call(app, "GET", "/admin/sessions")
      expect(body_of(resp)).to include("s-1", "s-2")
    end

    it "transcript rendered and escaped (XSS)" do
      msg = { "role" => "user", "content" => "<script>alert(1)</script>", "at" => "t" }
      app = build_app(sessions: { "s-1" => session("s-1", messages: [msg]) })

      _s, _h, resp = call(app, "GET", "/admin/sessions/s-1")
      html = body_of(resp)

      expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(html).not_to include("<script>alert(1)</script>")
    end

    it "non-existent session -> 404" do
      status, = call(build_app, "GET", "/admin/sessions/nope")
      expect(status).to eq(404)
    end

    it "task detail shows executions and checkpoint" do
      execution = Harness::TaskStore::Execution.new(
        attempt: 1, started_at: "a", finished_at: "b", outcome: "completed", error: nil
      )
      checkpoint = Harness::Checkpoint.new(
        task_id: "t-1", turn: 3, session_id: "s-1", agent_id: "sales",
        messages: [{ "role" => "user" }], completed_side_effects: ["c1"], created_at: "cx"
      )
      app = build_app(tasks: { "t-1" => task("t-1", executions: [execution]) },
                      checkpoints: { "t-1" => checkpoint })

      _s, _h, resp = call(app, "GET", "/admin/tasks/t-1")
      html = body_of(resp)
      expect(html).to include("completed") # execution outcome
      expect(html).to include("3")         # checkpoint turn
      expect(html).to include("c1")        # side effect
    end

    it "task without checkpoint -> 'sem checkpoint'" do
      app = build_app(tasks: { "t-1" => task("t-1") }, checkpoints: {})
      _s, _h, resp = call(app, "GET", "/admin/tasks/t-1")
      expect(body_of(resp)).to include("sem checkpoint")
    end

    it "events points EventSource to /v1/events" do
      _s, _h, resp = call(build_app, "GET", "/admin/events")
      html = body_of(resp)
      expect(html).to include("EventSource")
      expect(html).to include("/v1/events")
    end

    it "skills shows level 1 and body" do
      skill = Harness::SkillCatalog::Skill.new(
        name: "product_search", description: "product search", path: "/x", body: "# body"
      )
      _s, _h, resp = call(build_app(skills: [skill]), "GET", "/admin/skills")
      html = body_of(resp)
      expect(html).to include("product_search", "product search", "# body")
    end

    it "plugins groups by Entry#plugin" do
      tool = Harness::Registry::Entry.new(name: "get_weather", plugin: "weather",
                                          metadata: { optional: true }, factory: -> {})
      sys = Harness::Registry::Entry.new(name: "lookup_product", plugin: nil,
                                         metadata: {}, factory: -> {})
      app = build_app(tools: [tool, sys])

      _s, _h, resp = call(app, "GET", "/admin/plugins")
      html = body_of(resp)
      expect(html).to include("weather", "get_weather", "lookup_product", "(sistema)")
    end
  end

  describe "read-only enforcement" do
    it "POST /admin/... -> 404 and does NOT dispatch on the bus" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)

      status, = call(app, "POST", "/admin/tasks")

      expect(status).to eq(404)
      expect(bus.dispatched).to be_empty
    end
  end

  describe "strict CORS" do
    it "Origin in the allowlist -> access-control-allow-origin + vary" do
      app = build_app(allowed_origins: ["https://ops.example"])
      _s, headers, = call(app, "GET", "/admin", origin: "https://ops.example")
      expect(headers["access-control-allow-origin"]).to eq("https://ops.example")
      expect(headers["vary"]).to eq("origin")
    end

    it "Origin outside the allowlist -> no CORS headers" do
      app = build_app(allowed_origins: ["https://ops.example"])
      _s, headers, = call(app, "GET", "/admin", origin: "https://evil.example")
      expect(headers).not_to have_key("access-control-allow-origin")
    end

    it "preflight OPTIONS with allowed Origin -> 204 + allow-methods/headers" do
      app = build_app(allowed_origins: ["https://ops.example"])
      status, headers, = call(app, "OPTIONS", "/admin/tasks", auth: nil, origin: "https://ops.example")
      expect(status).to eq(204)
      expect(headers["access-control-allow-methods"]).to eq("GET, POST")
      expect(headers["access-control-allow-headers"]).to eq("authorization, content-type")
    end

    it "preflight OPTIONS with disallowed Origin -> 204 without CORS headers" do
      app = build_app(allowed_origins: ["https://ops.example"])
      status, headers, = call(app, "OPTIONS", "/admin/tasks", auth: nil, origin: "https://evil.example")
      expect(status).to eq(204)
      expect(headers).not_to have_key("access-control-allow-origin")
    end
  end
end
