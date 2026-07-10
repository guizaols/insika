# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/app"

# /admin read-only através do Server::App (auth + CORS + delegação exercitados
# juntos). Stores/catálogos/registries duplos; token correto no header.
RSpec.describe Harness::Server::Admin::App do
  # --- Duplos de leitura -------------------------------------------------
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
      executions: executions, mailbox_state: {}, claimed_by: nil, claim_expires_at: nil,
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
    it "sem token configurado -> 503 admin disabled" do
      status, _h, resp = call(build_app(admin_token: nil), "GET", "/admin")
      expect(status).to eq(503)
      expect(JSON.parse(body_of(resp))["error"]).to eq(
        "class" => "Harness::Error", "message" => "admin disabled"
      )
    end

    it "token errado -> 401 + www-authenticate" do
      status, headers, = call(build_app, "GET", "/admin", auth: "Bearer nope")
      expect(status).to eq(401)
      expect(headers["www-authenticate"]).to eq("Bearer")
    end

    it "token certo -> 200" do
      status, = call(build_app, "GET", "/admin")
      expect(status).to eq(200)
    end
  end

  describe "render read-only" do
    it "índice lista as 5 seções" do
      _s, headers, resp = call(build_app, "GET", "/admin")
      html = body_of(resp)
      expect(headers["content-type"]).to eq("text/html; charset=utf-8")
      %w[/admin/sessions /admin/tasks /admin/events /admin/skills /admin/plugins].each do |href|
        expect(html).to include(href)
      end
    end

    it "envia headers de segurança (CSP + nosniff) nas páginas" do
      _s, headers, = call(build_app, "GET", "/admin")
      expect(headers["x-content-type-options"]).to eq("nosniff")
      expect(headers["content-security-policy"]).to include("default-src 'none'", "connect-src 'self'")
    end

    it "lista sessões com ids" do
      app = build_app(sessions: { "s-1" => session("s-1"), "s-2" => session("s-2") })
      _s, _h, resp = call(app, "GET", "/admin/sessions")
      expect(body_of(resp)).to include("s-1", "s-2")
    end

    it "transcript renderizado e escapado (XSS)" do
      msg = { "role" => "user", "content" => "<script>alert(1)</script>", "at" => "t" }
      app = build_app(sessions: { "s-1" => session("s-1", messages: [msg]) })

      _s, _h, resp = call(app, "GET", "/admin/sessions/s-1")
      html = body_of(resp)

      expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(html).not_to include("<script>alert(1)</script>")
    end

    it "sessão inexistente -> 404" do
      status, = call(build_app, "GET", "/admin/sessions/nope")
      expect(status).to eq(404)
    end

    it "detalhe de task mostra executions e checkpoint" do
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
      expect(html).to include("completed") # outcome da execution
      expect(html).to include("3")         # turn do checkpoint
      expect(html).to include("c1")        # side effect
    end

    it "task sem checkpoint -> 'sem checkpoint'" do
      app = build_app(tasks: { "t-1" => task("t-1") }, checkpoints: {})
      _s, _h, resp = call(app, "GET", "/admin/tasks/t-1")
      expect(body_of(resp)).to include("sem checkpoint")
    end

    it "events aponta EventSource para /v1/events" do
      _s, _h, resp = call(build_app, "GET", "/admin/events")
      html = body_of(resp)
      expect(html).to include("EventSource")
      expect(html).to include("/v1/events")
    end

    it "skills mostra nível 1 e corpo" do
      skill = Harness::SkillCatalog::Skill.new(
        name: "product_search", description: "busca produtos", path: "/x", body: "# corpo"
      )
      _s, _h, resp = call(build_app(skills: [skill]), "GET", "/admin/skills")
      html = body_of(resp)
      expect(html).to include("product_search", "busca produtos", "# corpo")
    end

    it "plugins agrupa por Entry#plugin" do
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
    it "POST /admin/... -> 404 e NÃO despacha no bus" do
      bus = ServerBusDouble.new
      app = build_app(bus: bus)

      status, = call(app, "POST", "/admin/tasks")

      expect(status).to eq(404)
      expect(bus.dispatched).to be_empty
    end
  end

  describe "CORS estrito" do
    it "Origin na allowlist -> access-control-allow-origin + vary" do
      app = build_app(allowed_origins: ["https://ops.example"])
      _s, headers, = call(app, "GET", "/admin", origin: "https://ops.example")
      expect(headers["access-control-allow-origin"]).to eq("https://ops.example")
      expect(headers["vary"]).to eq("origin")
    end

    it "Origin fora da allowlist -> sem headers CORS" do
      app = build_app(allowed_origins: ["https://ops.example"])
      _s, headers, = call(app, "GET", "/admin", origin: "https://evil.example")
      expect(headers).not_to have_key("access-control-allow-origin")
    end

    it "preflight OPTIONS com Origin permitida -> 204 + allow-methods/headers" do
      app = build_app(allowed_origins: ["https://ops.example"])
      status, headers, = call(app, "OPTIONS", "/admin/tasks", auth: nil, origin: "https://ops.example")
      expect(status).to eq(204)
      expect(headers["access-control-allow-methods"]).to eq("GET")
      expect(headers["access-control-allow-headers"]).to eq("authorization")
    end

    it "preflight OPTIONS com Origin não permitida -> 204 sem headers CORS" do
      app = build_app(allowed_origins: ["https://ops.example"])
      status, headers, = call(app, "OPTIONS", "/admin/tasks", auth: nil, origin: "https://evil.example")
      expect(status).to eq(204)
      expect(headers).not_to have_key("access-control-allow-origin")
    end
  end
end
