# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../studio/app"

# Studio (Phase 4, Stage E) — Roda app mounted under /studio. Exercises cookie auth
# (D7, fail-closed), CSRF on POSTs, strict CSP (D8), serving of versioned assets and
# the login/agents/playground pages. Doubles in place of the runtime: the Studio only
# READS the ProfileSource and dispatches Commands on the bus (never writes to a store
# directly) — the same surface as Server::App.
RSpec.describe Studio::App do
  SessionDouble = Struct.new(:id)
  StoredSession = Struct.new(:id, :messages, :vars, :updated_at, keyword_init: true)

  BusDouble = Struct.new(:dispatched) do
    def dispatch(command)
      dispatched << command
      case command.type
      when :create_session then SessionDouble.new("sess-new")
      when :send_message then { task_id: "task-1" }
      when :set_skill_agents then { name: "x", enabled_for: [], skipped_all: [] }
      when :write_agent_file, :write_skill then { updated_at: "2026-07-12T00:00:00Z" }
      else { ok: true }
      end
    end

    def last(type) = dispatched.reverse.find { |c| c.type == type }
    def types = dispatched.map(&:type)
  end

  # ProfileSource duck-type: `all` (list) + `ids` + `fetch`.
  ProfileSourceDouble = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
    def fetch(id) = profiles.find { |p| p.id == id }
  end

  # Stage F read stores (only what the pages consume).
  SkillEntry = Struct.new(:name, :description, :body, keyword_init: true) # body: real catalog skills expose it (drill editor reads it)
  AgentFileStoreDouble = Struct.new(:files) do # files: { [agent, name] => content }
    def read(agent, name) = files[[agent, name.to_s]]
    def versions(_agent, _name) = []
  end
  SkillCatalogDouble = Struct.new(:skills) do
    def all = skills
    def find(name) = skills.find { |s| s.name == name.to_s }
  end
  SkillStoreDouble = Struct.new(:store) do # store: { name => content }
    def names = store.keys
    def get(name) = store[name.to_s]
  end
  ToolCatalogDouble = Struct.new(:tools) do
    def all = tools
  end
  MemoryStoreDouble = Struct.new(:by_tenant) do # by_tenant: { tenant => { facts:, notes: } }
    def facts(tenant:) = (by_tenant[tenant] || {})[:facts] || []
    def notes(tenant:, limit: nil) = (by_tenant[tenant] || {})[:notes] || []
  end
  SessionStoreDouble = Struct.new(:sessions) do # sessions: { id => StoredSession }
    def each_id(&blk) = block_given? ? sessions.keys.each(&blk) : sessions.keys.each
    def find(id) = sessions[id]
  end

  # §12 G5 — tasks/approvals read stores. Only the surface the pages consume.
  TaskDouble = Struct.new(:id, :status, :command, :session_id, :executions, :updated_at, keyword_init: true)
  ExecDouble = Struct.new(:attempt, :started_at, :finished_at, :outcome, :error, keyword_init: true)
  TaskStoreDouble = Struct.new(:tasks) do # tasks: { id => TaskDouble }
    def each_id(&blk) = block_given? ? tasks.keys.each(&blk) : tasks.keys.each
    def find(id) = tasks[id]
  end
  # NB: distinct names from the admin specs' PendingDouble/CheckpointDouble —
  # RSpec constants leak to top-level Object, so a shared name would clobber.
  StudioPendingRow = Struct.new(:id, :task_id, :turn, :tool, :args, :status, :requested_at, keyword_init: true)
  PendingStoreDouble = Struct.new(:pendings) do # pendings: [StudioPendingRow]
    def all_open = pendings.select { |p| p.status == :pending }
    def open_for(tid) = pendings.select { |p| p.status == :pending && p.task_id == tid }
  end
  StudioCheckpointRow = Struct.new(:turn, :messages, :completed_side_effects, :created_at, keyword_init: true)
  CheckpointStoreDouble = Struct.new(:by_task) do # by_task: { id => StudioCheckpointRow }
    def latest(id) = by_task[id]
  end

  def profile(id, model: "deepseek-chat", provider: :deepseek, memory: true,
              tools_allow: %w[menu calc], skills: %w[pedido], prompt_files: [])
    Insika::AgentProfile.build(id: id, model: model, provider: provider,
                                memory: memory, tools_allow: tools_allow,
                                skills: skills, prompt_files: prompt_files)
  end

  def build_app(admin_token: "s3cret", agents: [profile("bia"), profile("chef")],
                agent_files: {}, skills: [SkillEntry.new(name: "pedido", description: "faz pedido")],
                stored_skills: {}, tools: [SkillEntry.new(name: "menu", description: "cardápio")],
                data_tools: [], raw_data_tools: {}, memory: {}, sessions: {}, settings: nil, llm_providers: [],
                mcp_instances: [], system_files: {}, tool_traces: {},
                tasks: {}, pendings: [], checkpoints: {}, event_stream: nil)
    bus = BusDouble.new([])
    app = Class.new(Studio::App)
    # Stage G config stores: REAL over an in-memory ConfigStore (the Studio reads
    # from them when rendering; writes via the bus Commands). Seeded from the params
    # to exercise the settings/LLM/MCP/system-files read-path.
    cfg = Insika::ConfigStore.new(store: Insika::Stores::Memory.new)
    settings_store = Insika::SettingsStore.new(config_store: cfg)
    settings_store.update(settings) if settings
    provider_store = Insika::LLMProviderStore.new(config_store: cfg)
    llm_providers.each { |p| provider_store.upsert(p) }
    mcp_store = Insika::McpStore.new(config_store: cfg)
    mcp_instances.each { |m| mcp_store.upsert(m) }
    system_file_store = Insika::SystemFileStore.new(config_store: cfg)
    system_files.each { |name, content| system_file_store.write(name, content) }
    # REAL ToolStore (Phase 5): the authoring page reads from it; writes via the bus.
    tool_store = Insika::ToolStore.new(config_store: cfg)
    data_tools.each { |d| tool_store.write(d) }
    # Records written straight to the ConfigStore, BYPASSING validation — the only way to
    # seed a definition the engine no longer accepts (a legacy one). The editor has to
    # open those: it is where they get fixed.
    raw_data_tools.each do |name, definition|
      cfg.put("tools", name, { "definition" => definition, "updated_at" => "2026-01-01T00:00:00Z", "history" => [] })
    end
    # REAL ToolTraceStore (debug §3.1): the session view reads from it.
    trace_store = Insika::ToolTraceStore.new(store: Insika::Stores::Memory.new)
    tool_traces.each { |sid, entries| entries.each { |e| trace_store.record(session_id: sid, entry: e) } }
    app.configure(
      command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
      event_stream: event_stream, config: { admin_token: admin_token },
      agent_file_store: AgentFileStoreDouble.new(agent_files),
      skill_store: SkillStoreDouble.new(stored_skills),
      skill_catalog: SkillCatalogDouble.new(skills),
      tool_catalog: ToolCatalogDouble.new(tools),
      tool_store: tool_store,
      memory_store: MemoryStoreDouble.new(memory),
      session_store: SessionStoreDouble.new(sessions),
      settings_store: settings_store, llm_provider_store: provider_store,
      mcp_store: mcp_store, system_file_store: system_file_store,
      tool_trace_store: trace_store,
      task_store: TaskStoreDouble.new(tasks),
      pending_action_store: PendingStoreDouble.new(pendings),
      checkpoint_store: CheckpointStoreDouble.new(checkpoints),
      session_secret: "x" * 64
    )
    [app, bus]
  end

  # Client that carries cookies between requests (session + CSRF live in the cookie).
  class Client
    attr_reader :cookie

    def initialize(app) = (@mock = Rack::MockRequest.new(app); @cookie = nil)

    def get(path) = capture(@mock.get(path, headers))
    def post(path, params: {}) = capture(@mock.post(path, headers.merge(params: params)))

    private

    def headers = @cookie ? { "HTTP_COOKIE" => @cookie } : {}

    def capture(res)
      if (sc = res.headers["set-cookie"])
        @cookie = Array(sc).map { |c| c.split(";").first }.join("; ")
      end
      res
    end
  end

  def csrf_from(html) = html[/name="_csrf" value="([^"]+)"/, 1]

  # Does the full login (GET for cookie+token, POST with the token) and returns the
  # authenticated client.
  def login(app, token: "s3cret")
    client = Client.new(app)
    form = client.get("/login")
    csrf = csrf_from(form.body)
    client.post("/login", params: { "token" => token, "_csrf" => csrf })
    client
  end

  # --- Auth / fail-closed --------------------------------------------------

  it "shows the login without a session (GET /login = 200 with form and CSRF)" do
    app, = build_app
    res = Client.new(app).get("/login")
    expect(res.status).to eq(200)
    expect(res.body).to include('name="token"')
    expect(res.body).to include('name="_csrf"')
  end

  it "redirects protected routes to /studio/login without a session (fail-closed)" do
    app, = build_app
    res = Client.new(app).get("/agents")
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/login")
  end

  it "authenticates with the correct token and starts serving the pages" do
    app, = build_app
    client = login(app, token: "s3cret")
    res = client.get("/agents")
    expect(res.status).to eq(200)
    expect(res.body).to include("bia")
    expect(res.body).to include("chef")
  end

  it "rejects an incorrect token (401, no session)" do
    app, = build_app
    client = Client.new(app)
    csrf = csrf_from(client.get("/login").body)
    res = client.post("/login", params: { "token" => "errado", "_csrf" => csrf })
    expect(res.status).to eq(401)
    # session was not marked: a protected route still redirects
    expect(client.get("/agents").status).to eq(302)
  end

  it "is fail-closed when no token is configured (login never validates)" do
    app, = build_app(admin_token: "")
    client = Client.new(app)
    csrf = csrf_from(client.get("/login").body)
    res = client.post("/login", params: { "token" => "qualquer", "_csrf" => csrf })
    expect(res.status).to eq(401)
  end

  it "logs out by clearing the session" do
    app, = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    expect(client.post("/logout", params: { "_csrf" => csrf }).status).to eq(302)
    expect(client.get("/agents").status).to eq(302) # session cleared → back to login
  end

  # --- CSRF ----------------------------------------------------------------

  it "blocks a POST without a CSRF token (403)" do
    app, = build_app
    # session obtained via GET, but POST without _csrf
    client = Client.new(app)
    client.get("/login")
    res = client.post("/login", params: { "token" => "s3cret" })
    expect(res.status).to eq(403)
  end

  # --- CSP / headers -------------------------------------------------------

  it "sends strict CSP 'self' (no unsafe-inline) and nosniff" do
    app, = build_app
    res = Client.new(app).get("/login")
    csp = res.headers["content-security-policy"]
    expect(csp).to include("script-src 'self'")
    expect(csp).to include("style-src 'self'")
    expect(csp).not_to include("unsafe-inline")
    expect(res.headers["x-content-type-options"]).to eq("nosniff")
  end

  it "whitelists a nonce on style-src and exposes it via <meta> (CodeMirror/Turbo)" do
    app, = build_app
    res = Client.new(app).get("/login")
    csp = res.headers["content-security-policy"]
    expect(csp).to match(/style-src 'self' 'nonce-[^']+'/)
    nonce = csp[/'nonce-([^']+)'/, 1]
    # same nonce reaches the page — the editor reads it (EditorView.cspNonce), Turbo too
    expect(res.body).to include(%(<meta name="csp-nonce" content="#{nonce}">))
  end

  it "keeps the CSP nonce stable within a session (Turbo+CodeMirror), distinct across sessions" do
    app, = build_app
    c1 = Client.new(app)
    # Same session → same nonce on every response: the browser enforces the initial
    # document's CSP for the whole SPA session, so Turbo-fetched pages must carry the
    # SAME nonce or CodeMirror's injected <style> gets blocked (unstyled editor).
    n1a = c1.get("/login").headers["content-security-policy"][/'nonce-([^']+)'/, 1]
    n1b = c1.get("/login").headers["content-security-policy"][/'nonce-([^']+)'/, 1]
    expect(n1a).not_to be_nil
    expect(n1a).to eq(n1b)
    # Different session → different nonce (still unguessable, per-user).
    n2 = Client.new(app).get("/login").headers["content-security-policy"][/'nonce-([^']+)'/, 1]
    expect(n2).not_to eq(n1a)
  end

  # --- Assets --------------------------------------------------------------

  it "serves the versioned bundle with the correct content-type" do
    app, = build_app
    res = Client.new(app).get("/assets/dist/application.css")
    expect(res.status).to eq(200)
    expect(res.headers["content-type"]).to include("text/css")
    expect(res.headers["cache-control"]).to eq("no-cache") # never serve a stale rebuild
  end

  it "doesn't escape the dist dir (path traversal → 404)" do
    app, = build_app
    res = Client.new(app).get("/assets/dist/..%2f..%2fapp.rb")
    expect(res.status).to eq(404)
  end

  # --- Playground ----------------------------------------------------------

  it "dispatches send_message via the bus and redirects (no direct writes)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    res = client.post("/playground", params: {
                        "agent" => "bia", "session_id" => "s1",
                        "message" => "oi", "_csrf" => csrf
                      })
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to include("session_id=s1")
    expect(bus.dispatched.size).to eq(1)
    cmd = bus.dispatched.first
    expect(cmd.type).to eq(:send_message)
    expect(cmd.payload[:message]).to eq("oi")
    expect(cmd.meta[:transport]).to eq(:studio)
  end

  it "creates a new session when session_id comes in blank" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    res = client.post("/playground", params: {
                        "agent" => "bia", "session_id" => "", "message" => "oi", "_csrf" => csrf
                      })
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to include("session_id=sess-new")
    types = bus.dispatched.map(&:type)
    expect(types).to eq(%i[create_session send_message])
  end

  it "playground GET lists the agents in the selector" do
    app, = build_app
    client = login(app)
    res = client.get("/playground?agent=chef")
    expect(res.status).to eq(200)
    expect(res.body).to include('value="chef"')
    expect(res.body).to include('data-controller="live-transcript"')
  end

  it "escapes dynamic content exactly once (no double-escape, XSS-safe)" do
    app, = build_app(agents: [profile("bia", model: "modelo&<x>")])
    client = login(app)
    body = client.get("/agents").body
    expect(body).to include("modelo&amp;&lt;x&gt;")   # escaped 1×
    expect(body).not_to include("&amp;amp;")           # NOT double-escaped
    expect(body).not_to include("modelo&<x>")          # NOT raw
  end

  it "responds with a friendly 404 on an unknown authenticated route" do
    app, = build_app
    client = login(app)
    res = client.get("/inexistente")
    expect(res.status).to eq(404)
    expect(res.body).to include("404")
  end

  it "playground sends tenant = agent in send_message (per-agent memory)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: { "agent" => "chef", "session_id" => "s1",
                                          "message" => "oi", "_csrf" => csrf })
    expect(bus.last(:send_message).meta[:tenant]).to eq("chef")
  end

  it "playground pins the model on a NEW conversation via create_session (v2 §10)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: {
                  "agent" => "chef", "session_id" => "", "message" => "oi",
                  "model" => "deepseek-reasoner", "provider" => "deepseek", "_csrf" => csrf
                })
    cmd = bus.last(:create_session)
    expect(cmd.payload[:model]).to eq("deepseek-reasoner")
    expect(cmd.payload[:provider]).to eq("deepseek")
  end

  it "playground passes the per-chat reasoning override (thinking) to create_session" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: {
                  "agent" => "chef", "session_id" => "", "message" => "oi",
                  "thinking" => "off", "_csrf" => csrf
                })
    expect(bus.last(:create_session).payload[:thinking]).to eq("off")
  end

  it "playground does NOT create a session (nor pin) when continuing an existing one" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: {
                  "agent" => "chef", "session_id" => "s1", "message" => "oi",
                  "model" => "deepseek-reasoner", "_csrf" => csrf
                })
    expect(bus.types).not_to include(:create_session)
  end

  it "playground echoes the just-sent message as a user bubble on the next GET (§11 A1)" do
    app, = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: { "agent" => "chef", "session_id" => "s1",
                                          "message" => "olá-echo-42", "_csrf" => csrf })
    body = client.get("/playground?agent=chef&session_id=s1").body
    expect(body).to include("olá-echo-42")
    expect(body).to include('class="msg user"')
  end

  it "playground GET renders the session's persisted transcript as bubbles (§11 A1)" do
    sess = StoredSession.new(id: "s1", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "pergunta-persistida" },
                                        { "role" => "assistant", "content" => "resposta-persistida" }])
    app, = build_app(sessions: { "s1" => sess })
    body = login(app).get("/playground?agent=chef&session_id=s1").body
    expect(body).to include("pergunta-persistida")
    expect(body).to include("resposta-persistida")
    expect(body).to include('data-controller="markdown"') # assistant bubble renders Markdown
  end

  it "the app-bar has the skills and tools links (Stage F)" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('href="/studio/skills"')
    expect(body).to include('href="/studio/tools"')
  end

  # --- Agents (detail) — task 15/17 ----------------------------------------

  it "renders the agent detail with config, prompts, skills, memory and history" do
    app, = build_app
    res = login(app).get("/agents/bia")
    expect(res.status).to eq(200)
    %w[config prompts skills memory history].each { |a| expect(res.body).to include("id=\"#{a}\"") }
    expect(res.body).to include('name="model"')
    expect(res.body).to include('data-controller="code-editor"')
  end

  it "404 on the detail of a nonexistent agent" do
    app, = build_app
    expect(login(app).get("/agents/nao-existe").status).to eq(404)
  end

  # Regression (found running for real): Roda's String matcher delivers the path
  # segment in ASCII-8BIT; a `get` on the SQLite store with a binary key doesn't
  # match the key written in UTF-8 (bound as BLOB) and the detail 404'd. The edge
  # normalizes to UTF-8 (`utf8`). Doubles don't reproduce it (String#== is
  # encoding-agnostic for ASCII) — this test uses real SQLite + a binary PATH_INFO.
  it "resolves a binary path id against the SQLite store (encoding regression)" do
    require "tmpdir"
    Dir.mktmpdir do |dir|
      store = Insika::Stores::SQLite.new(path: File.join(dir, "cfg.db"))
      src = Insika::StoredProfileSource.new(config_store: Insika::ConfigStore.new(store: store))
      src.put(Insika::AgentProfile.build(id: "bia", model: "m", provider: :deepseek, memory: true))
      app = Class.new(Studio::App)
      app.configure(command_bus: BusDouble.new([]), profile_source: src, event_stream: nil,
                    config: { admin_token: "s3cret" },
                    agent_file_store: AgentFileStoreDouble.new({}),
                    skill_catalog: SkillCatalogDouble.new([]),
                    memory_store: MemoryStoreDouble.new({}),
                    session_store: SessionStoreDouble.new({}), session_secret: "x" * 64)
      client = login(app)
      env = Rack::MockRequest.env_for("/agents/bia", "HTTP_COOKIE" => client.cookie)
      env["PATH_INFO"] = env["PATH_INFO"].dup.force_encoding(Encoding::ASCII_8BIT)
      status, = app.call(env)
      expect(status).to eq(200)
    end
  end

  it "config dispatches update_agent with memory bool and limits int" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    res = client.post("/agents/bia/config", params: {
                        "model" => "deepseek-reasoner", "provider" => "deepseek",
                        "memory" => "1", "turn_timeout" => "90", "_csrf" => csrf
                      })
    expect(res.status).to eq(302)
    cmd = bus.last(:update_agent)
    expect(cmd.payload[:model]).to eq("deepseek-reasoner")
    expect(cmd.payload[:memory]).to be(true)
    expect(cmd.payload[:limits][:turn_timeout]).to eq(90)
  end

  # Item 30: the third tool-execution bound sits in the same form as the two
  # timeouts, so an operator can turn parallel tool calls on without the DSL.
  it "config writes tool_concurrency, and a blank field keeps what is stored" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "tool_concurrency" => "4", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:limits][:tool_concurrency]).to eq(4)

    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "tool_concurrency" => "", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:limits][:tool_concurrency]).to eq(1) # DEFAULT_LIMITS
  end

  it "config without the memory checkbox writes memory=false" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:memory]).to be(false)
  end

  it "config writes the per-agent edge overrides; blank DELETES them (inherit platform)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: {
                  "model" => "x", "chat_rate_limit" => "5", "agent_token_ceiling" => "0", "_csrf" => csrf
                })
    limits = bus.last(:update_agent).payload[:limits]
    expect(limits[:chat_rate_limit]).to eq(5)
    expect(limits[:agent_token_ceiling]).to eq(0) # 0 = explicitly off for this agent

    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "chat_rate_limit" => "", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:limits]).not_to have_key(:chat_rate_limit)
  end

  # --- config v2 (§10) surfacing -------------------------------------------

  it "config with a blank model clears it (inherit the platform default)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:model]).to be_nil
  end

  it "config builds generation params with NUMERIC types (executor guards on numeric?)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: {
                  "model" => "x", "temperature" => "0.7", "max_tokens" => "4096",
                  "thinking" => "high", "_csrf" => csrf
                })
    params = bus.last(:update_agent).payload[:params]
    expect(params["temperature"]).to eq(0.7)
    expect(params["temperature"]).to be_a(Float)
    expect(params["max_tokens"]).to eq(4096)
    expect(params["max_tokens"]).to be_a(Integer)
    expect(params["thinking"]).to eq("high")
  end

  it "config drops a malformed number instead of 500-ing the save" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    res = client.post("/agents/bia/config", params: {
                        "model" => "x", "temperature" => "hot", "_csrf" => csrf
                      })
    expect(res.status).to eq(302)
    expect(bus.last(:update_agent).payload[:params]).not_to have_key("temperature")
  end

  it "config builds model_policy from the allow textarea; blank = nil (no fence)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: {
                  "model" => "x", "model_policy_allow" => "deepseek/*\nopenai/gpt-4o-mini",
                  "_csrf" => csrf
                })
    expect(bus.last(:update_agent).payload[:model_policy]).to eq("allow" => %w[deepseek/* openai/gpt-4o-mini])

    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "model_policy_allow" => "", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:model_policy]).to be_nil
  end

  it "saving a prompt dispatches write_agent_file (the Command syncs prompt_files)" do
    app, bus = build_app # bia has prompt_files: []
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts", params: {
                  "file" => "IDENTITY.md", "content" => "# Eu", "_csrf" => csrf
                })
    expect(bus.last(:write_agent_file).payload).to include(agent_id: "bia", file: "IDENTITY.md")
    expect(bus.types).not_to include(:update_agent) # prompt_files sync belongs to the Command
  end

  it "removing a prompt dispatches delete_agent_file (the Command removes it from prompt_files)" do
    app, bus = build_app(agents: [profile("bia", prompt_files: %w[IDENTITY.md SOUL.md])])
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts/delete", params: { "file" => "SOUL.md", "_csrf" => csrf })
    expect(bus.last(:delete_agent_file).payload).to include(agent_id: "bia", file: "SOUL.md")
    expect(bus.types).not_to include(:update_agent)
  end

  it "restoring a prompt dispatches restore_agent_file with version" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts/restore", params: {
                  "file" => "IDENTITY.md", "version" => "2", "_csrf" => csrf
                })
    expect(bus.last(:restore_agent_file).payload).to include(agent_id: "bia", file: "IDENTITY.md", version: "2")
  end

  it "skills 'all' dispatches update_agent with skills nil" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/skills", params: { "all_skills" => "1", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload).to include(skills: nil)
  end

  it "skills subset dispatches update_agent with the checked list" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/skills", params: { "skills" => ["pedido"], "_csrf" => csrf })
    expect(bus.last(:update_agent).payload).to include(skills: ["pedido"])
  end

  it "memory: fact/forget/note dispatch scoped by tenant = agent id" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/memory/fact", params: { "key" => "nome", "value" => "Ana", "_csrf" => csrf })
    client.post("/agents/bia/memory/forget", params: { "key" => "nome", "_csrf" => csrf })
    client.post("/agents/bia/memory/note", params: { "text" => "gosta de doce", "_csrf" => csrf })
    expect(bus.last(:memory_put_fact).payload).to include(tenant: "bia", key: "nome", value: "Ana")
    expect(bus.last(:memory_forget_fact).payload).to include(tenant: "bia", key: "nome")
    expect(bus.last(:memory_add_note).payload).to include(tenant: "bia", text: "gosta de doce")
  end

  it "detail shows the agent's memory facts (tenant = id)" do
    fact = Insika::MemoryStore::Fact.new(key: "nome", value: "Ana", updated_at: "t")
    app, = build_app(memory: { "bia" => { facts: [fact], notes: [] } })
    body = login(app).get("/agents/bia").body
    expect(body).to include("nome")
    expect(body).to include("Ana")
  end

  # --- Skills (index + editor) — task 16 -----------------------------------

  it "lists the skills and the agents matrix" do
    app, = build_app
    body = login(app).get("/skills").body
    expect(body).to include("pedido")               # skill from the catalog
    expect(body).to include('name="agent_ids[]"')   # matrix
  end

  it "new skill editor brings the template with frontmatter" do
    app, = build_app
    body = login(app).get("/skills/new").body
    expect(body).to include('data-controller="code-editor"')
    expect(body).to include("name:")
  end

  it "existing skill editor brings the content from the store" do
    app, = build_app(stored_skills: { "pedido" => "---\nname: pedido\n---\nauthored body" })
    body = login(app).get("/skills/pedido").body
    expect(body).to include("authored body")
  end

  it "saving a skill dispatches write_skill" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/skills/new").body)
    res = client.post("/skills", params: { "name" => "reembolso", "content" => "---\nname: reembolso\n---\nx", "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(bus.last(:write_skill).payload).to include(name: "reembolso")
  end

  it "applying a skill to the agents dispatches set_skill_agents with agent_ids" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/skills").body)
    client.post("/skills/pedido/agents", params: { "agent_ids" => %w[bia chef], "_csrf" => csrf })
    cmd = bus.last(:set_skill_agents)
    expect(cmd.payload[:name]).to eq("pedido")
    expect(cmd.payload[:agent_ids]).to eq(%w[bia chef])
  end

  # --- Tools (matriz) — task 16 --------------------------------------------

  it "lists the tools-by-agent matrix" do
    app, = build_app
    body = login(app).get("/tools").body
    expect(body).to include("menu")               # tool from the catalog
    expect(body).to include('name="all_tools"')
  end

  it "renders the §3.2 matrix affordances: filter box, live counter, switch toggle" do
    app, = build_app
    body = login(app).get("/tools").body
    expect(body).to include('data-controller="list-filter"')
    expect(body).to include('data-toggle-counter-target="count"')
    expect(body).to include('class="switch"')
  end

  it "renders a denied tool as LOCKED (disabled, deny wins) — can't be granted here" do
    denied = Insika::AgentProfile.build(id: "bia", tools_allow: nil, tools_deny: %w[menu])
    app, = build_app(agents: [denied])
    body = login(app).get("/tools").body
    expect(body).to include("locked")
    # the denied tool's checkbox is disabled so it never enters the submitted allowlist
    expect(body).to match(/name="tools\[\]" value="menu"[^>]*disabled/)
  end

  it "tools 'all' dispatches set_agent_tools with allow nil" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/tools").body)
    client.post("/tools/bia", params: { "all_tools" => "1", "_csrf" => csrf })
    expect(bus.last(:set_agent_tools).payload).to include(id: "bia", allow: nil)
  end

  it "tools subset dispatches set_agent_tools with the list and preserves the deny" do
    app, bus = build_app(agents: [profile("bia", tools_allow: %w[menu calc])])
    client = login(app)
    csrf = csrf_from(client.get("/tools").body)
    client.post("/tools/bia", params: { "tools" => ["menu"], "_csrf" => csrf })
    cmd = bus.last(:set_agent_tools)
    expect(cmd.payload[:allow]).to eq(["menu"])
    expect(cmd.payload).to have_key(:deny)
  end

  # The live transcript's SSE. It used to read the server's /v1/events straight from the
  # browser — EventSource cannot send a Bearer — which is why that route had to stay open
  # to the world while streaming assistant text. The stream now rides the Studio's own
  # cookie, so /v1 could close.
  describe "GET /events (live transcript SSE)" do
    # Records what the island asked to subscribe to. The body is NEVER drained here:
    # SSEBody exposes #call (Rack 3 streaming), not #each, on purpose.
    let(:stream_double) do
      Class.new do
        attr_reader :scope

        def subscribe(task_id:, session_id:) = (@scope = { task_id: task_id, session_id: session_id }; self)
      end.new
    end

    it "answers the SSE headers with a streaming body, scoped to the session" do
      app, = build_app(event_stream: stream_double)
      client = login(app)
      env = Rack::MockRequest.env_for("/events?session_id=sess-1", "HTTP_COOKIE" => client.cookie)
      status, headers, body = app.call(env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(headers["cache-control"]).to eq("no-cache")
      expect(body).to be_a(Insika::Server::SSEBody)
      expect(stream_double.scope).to eq(task_id: nil, session_id: "sess-1")
    end

    it "is behind the session like every other page (anonymous -> login)" do
      app, = build_app(event_stream: stream_double)
      resp = Rack::MockRequest.new(app).get("/events?session_id=sess-1")
      expect(resp.status).to eq(302)
      expect(resp.headers["location"]).to eq("/studio/login")
    end

    it "404s when no event stream is wired (the feature is not there)" do
      app, = build_app # event_stream: nil
      expect(login(app).get("/events").status).to eq(404)
    end
  end

  # --- Data-driven tools (authoring) — Phase 5 Stage C ---------------------

  def data_tool(name: "cep", **over)
    { name: name, description: "Consulta #{name}",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" } }.merge(over)
  end

  it "matrix lists the data-tools, marks them with a badge and links the editor" do
    app, = build_app(data_tools: [data_tool(name: "cep")],
                     tools: [SkillEntry.new(name: "cep", description: "Consulta cep"),
                             SkillEntry.new(name: "menu", description: "cardápio")])
    body = login(app).get("/tools").body
    expect(body).to include('href="/studio/tools/def/cep"')      # editor link
    expect(body).to include('href="/studio/tools/def/new"')      # new tool
    expect(body).to include(">data<")                             # badge in the matrix
  end

  # A data tool the overlay refuses is absent from the catalog (and from every agent's
  # matrix) with only a stderr warn. The panel still lists it from the store, so this is
  # where you notice — and the editor link is how you fix it.
  it "marks a stored data tool that is missing from the catalog as dropped" do
    app, = build_app(data_tools: [data_tool(name: "cep")],
                     tools: [SkillEntry.new(name: "menu", description: "cardápio")])
    body = login(app).get("/tools").body
    expect(body).to include('href="/studio/tools/def/cep"')
    expect(body).to include(">dropped<")
  end

  it "does not mark a registered data tool as dropped" do
    app, = build_app(data_tools: [data_tool(name: "cep")],
                     tools: [SkillEntry.new(name: "cep", description: "Consulta cep")])
    expect(login(app).get("/tools").body).not_to include(">dropped<")
  end

  it "opens the editor for a legacy definition the engine now refuses, spelling the array out" do
    legacy = { "name" => "recommend_products", "description" => "destaca produtos",
               "parameters" => [{ "name" => "products", "type" => "array", "required" => true,
                                  "description" => "os UUIDs" }],
               "request" => { "method" => "POST", "url" => "https://api.test/x", "headers" => {},
                              "query" => {}, "body" => '{"p":{{products}}}' },
               "response" => { "extract" => "body_raw", "path" => nil },
               "secret_headers" => [], "side_effect" => true, "timeout" => nil }
    app, = build_app(raw_data_tools: { "recommend_products" => legacy })
    body = login(app).get("/tools/def/recommend_products").body
    expect(body).to include("products | array:string | required | os UUIDs")
  end

  it "GET /tools/def/new renders the empty form" do
    app, = build_app
    body = login(app).get("/tools/def/new").body
    expect(body).to include('action="/studio/tools/def"')
    expect(body).to include("New data tool")
  end

  it "POST /tools/def creates: dispatches :write_data_tool with the nested payload + create_only" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/tools/def/new").body)
    client.post("/tools/def", params: {
                  "name" => "cep", "description" => "Consulta CEP", "method" => "GET",
                  "url" => "https://viacep.com.br/ws/{{cep}}/json",
                  "parameters" => "cep | string | required | O CEP",
                  "extract" => "json_path", "path" => "localidade", "_csrf" => csrf
                })
    p = bus.last(:write_data_tool).payload
    expect(p[:name]).to eq("cep")
    expect(p[:request][:url]).to eq("https://viacep.com.br/ws/{{cep}}/json")
    expect(p[:parameters]).to eq([{ "name" => "cep", "type" => "string", "required" => true, "description" => "O CEP" }])
    expect(p[:response]).to eq(extract: "json_path", path: "localidade")
    expect(p[:create_only]).to be(true)
  end

  it "GET /tools/def/:name loads the editor with the secret MASKED (0 leakage)" do
    secret = data_tool(name: "api", request: {
                         method: "POST", url: "https://api.test/x",
                         headers: { "Authorization" => "Bearer TOPSECRET" }
                       }, secret_headers: ["Authorization"])
    app, = build_app(data_tools: [secret])
    body = login(app).get("/tools/def/api").body
    expect(body).to include(Insika::SecretMasking::SENTINEL)
    expect(body).not_to include("TOPSECRET")
  end

  it "POST /tools/def/:name updates (upsert, no create_only)" do
    app, bus = build_app(data_tools: [data_tool(name: "cep")])
    client = login(app)
    csrf = csrf_from(client.get("/tools/def/cep").body)
    client.post("/tools/def/cep", params: {
                  "name" => "cep", "description" => "nova desc", "method" => "GET",
                  "url" => "https://viacep.com.br/ws/{{cep}}/json", "_csrf" => csrf
                })
    p = bus.last(:write_data_tool).payload
    expect(p[:description]).to eq("nova desc")
    expect(p).not_to have_key(:create_only)
  end

  it "POST /tools/def/:name/delete dispatches :delete_data_tool" do
    app, bus = build_app(data_tools: [data_tool(name: "cep")])
    client = login(app)
    csrf = csrf_from(client.get("/tools/def/cep").body)
    client.post("/tools/def/cep/delete", params: { "_csrf" => csrf })
    expect(bus.last(:delete_data_tool).payload).to include(name: "cep")
  end

  it "POST /tools/def/:name/restore dispatches :restore_data_tool with index" do
    app, bus = build_app(data_tools: [data_tool(name: "cep")])
    client = login(app)
    csrf = csrf_from(client.get("/tools/def/cep").body)
    client.post("/tools/def/cep/restore", params: { "index" => "0", "_csrf" => csrf })
    expect(bus.last(:restore_data_tool).payload).to include(name: "cep", index: "0")
  end

  it "GET /tools/def/:name nonexistent → 404" do
    app, = build_app
    expect(login(app).get("/tools/def/fantasma").status).to eq(404)
  end

  # The editor used to render only the TOP LEVEL of a nested schema and write the flat
  # form back — so opening a nested tool and saving it silently replaced its schema with
  # one its author never wrote (an array of objects became an array of strings).
  describe "nested parameters (the editor must not flatten)" do
    let(:nested_schema) do
      { "type" => "object",
        "properties" => {
          "query_filter_pairs" => {
            "type" => "array",
            "items" => { "type" => "object",
                         "properties" => { "query" => { "type" => "string" },
                                           "filters" => { "type" => "object", "properties" => {} } },
                         "required" => ["query"] }
          }
        },
        "required" => ["query_filter_pairs"] }
    end

    def nested_tool
      data_tool(name: "search_products", parameters: nested_schema,
                request: { method: "POST", url: "https://api.test/search",
                           body: '{"pairs":{{query_filter_pairs}}}' },
                response: { extract: "body_raw" })
    end

    it "renders the schema as JSON, not as a lossy flat line" do
      app, = build_app(data_tools: [nested_tool])
      body = login(app).get("/tools/def/search_products").body
      expect(body).to include("&quot;items&quot;")               # the nesting is on screen
      expect(body).to include("&quot;query_filter_pairs&quot;")
      expect(body).not_to include("query_filter_pairs | array")  # the old flat rendering
    end

    it "round-trips: saving what the editor rendered writes the SAME schema back" do
      app, bus = build_app(data_tools: [nested_tool])
      client = login(app)
      page = client.get("/tools/def/search_products").body
      rendered = CGI.unescapeHTML(page[%r{<textarea name="parameters"[^>]*>(.*?)</textarea>}m, 1])
      client.post("/tools/def/search_products", params: {
                    "name" => "search_products", "description" => "busca", "method" => "POST",
                    "url" => "https://api.test/search", "body" => '{"pairs":{{query_filter_pairs}}}',
                    "parameters" => rendered, "extract" => "body_raw", "_csrf" => csrf_from(page)
                  })
      expect(bus.last(:write_data_tool).payload[:parameters]).to eq(nested_schema)
    end

    it "invalid JSON is a flash error, not a write" do
      app, bus = build_app(data_tools: [nested_tool])
      client = login(app)
      csrf = csrf_from(client.get("/tools/def/search_products").body)
      client.post("/tools/def/search_products", params: {
                    "name" => "search_products", "description" => "busca", "method" => "POST",
                    "url" => "https://api.test/search", "parameters" => '{"type":"object",', "_csrf" => csrf
                  })
      expect(bus.last(:write_data_tool)).to be_nil
      expect(client.get("/tools/def/search_products").body).to include("invalid JSON Schema")
    end
  end

  it "a list of scalars round-trips through the flat form as array:string" do
    app, bus = build_app(data_tools: [data_tool(
      name: "recommend_products",
      parameters: { "type" => "object",
                    "properties" => { "products" => { "type" => "array", "items" => { "type" => "string" } } },
                    "required" => ["products"] },
      request: { method: "POST", url: "https://api.test/x", body: '{"p":{{products}}}' },
      response: { extract: "body_raw" }
    )])
    client = login(app)
    page = client.get("/tools/def/recommend_products").body
    expect(page).to include("products | array:string | required")

    client.post("/tools/def/recommend_products", params: {
                  "name" => "recommend_products", "description" => "d", "method" => "POST",
                  "url" => "https://api.test/x", "body" => '{"p":{{products}}}',
                  "parameters" => "products | array:string | required | os UUIDs",
                  "extract" => "body_raw", "_csrf" => csrf_from(page)
                })
    expect(bus.last(:write_data_tool).payload[:parameters])
      .to eq([{ "name" => "products", "type" => "array:string", "required" => true, "description" => "os UUIDs" }])
  end

  # --- History (read-only viewer) — task 17 --------------------------------

  it "session viewer renders the read-only transcript" do
    sess = StoredSession.new(id: "sess-xyz", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "oi" },
                                        { "role" => "assistant", "content" => "olá!" }])
    app, = build_app(sessions: { "sess-xyz" => sess })
    body = login(app).get("/sessions/sess-xyz").body
    expect(body).to include("olá!")
    expect(body).to include("Continue in playground")
  end

  it "404 on a nonexistent session" do
    app, = build_app
    expect(login(app).get("/sessions/nope").status).to eq(404)
  end

  it "session viewer shows the tool-calls trace (name + args + response)" do
    sess = StoredSession.new(id: "sess-t", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    traces = { "sess-t" => [{ "turn" => 1, "tool" => "search_products", "call_id" => "c1",
                              "args" => { "query" => "trufa" }, "result" => { "found" => 3 },
                              "ms" => 40, "at" => "2026-07-16T00:00:00Z" }] }
    app, = build_app(sessions: { "sess-t" => sess }, tool_traces: traces)
    body = login(app).get("/sessions/sess-t").body
    expect(body).to include("Tool calls")
    expect(body).to include("search_products")
    expect(body).to include("trufa")   # rendered args
    expect(body).to include("found")   # rendered response
  end

  it "session viewer renders structured content as pretty JSON, not Ruby #inspect (§11 A2)" do
    sess = StoredSession.new(id: "sess-j", updated_at: "t",
                             messages: [{ "role" => "assistant", "content" => { "text" => "hi" } }])
    app, = build_app(sessions: { "sess-j" => sess })
    body = login(app).get("/sessions/sess-j").body
    expect(body).to include("&quot;text&quot;") # JSON quotes, escaped once
    expect(body).not_to include("=&gt;")         # NOT a Ruby hashrocket (#inspect)
  end

  it "session viewer renders a tool message as a collapsible card (§11 A2)" do
    sess = StoredSession.new(id: "sess-tool", updated_at: "t",
                             messages: [{ "role" => "tool", "content" => "resultado-da-tool" }])
    app, = build_app(sessions: { "sess-tool" => sess })
    body = login(app).get("/sessions/sess-tool").body
    expect(body).to include("resultado-da-tool")
    expect(body).to include('class="toolcard result"')
  end

  it "session viewer renders an assistant's tool_calls as cards (§11 R1)" do
    sess = StoredSession.new(id: "sess-tc", updated_at: "t",
                             messages: [{ "role" => "assistant", "content" => "",
                                          "tool_calls" => [{ "id" => "c1", "name" => "search_products",
                                                             "arguments" => { "q" => "trufa" } }] }])
    app, = build_app(sessions: { "sess-tc" => sess })
    body = login(app).get("/sessions/sess-tc").body
    expect(body).to include("search_products")
    expect(body).to include("trufa")
  end

  it "the detail's history lists the recent conversations" do
    sess = StoredSession.new(id: "sess-abc123456789", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-abc123456789" => sess })
    body = login(app).get("/agents/bia").body
    expect(body).to include("/studio/sessions/sess-abc123456789")
  end

  # --- Settings (task 18) --------------------------------------------------

  it "the app-bar has the Stage G links (mcp/system/chats/settings)" do
    app, = build_app
    body = login(app).get("/agents").body
    %w[/studio/mcp /studio/system-files /studio/chats /studio/settings].each do |href|
      expect(body).to include("href=\"#{href}\"")
    end
  end

  it "settings renders the defaults and dispatches update_settings with native types" do
    app, bus = build_app
    client = login(app)
    res = client.get("/settings")
    expect(res.status).to eq(200)
    expect(res.body).to include('name="turn_timeout"')
    csrf = csrf_from(res.body)
    client.post("/settings", params: {
                  "streaming" => "1", "turn_timeout" => "300", "keep_last" => "40",
                  "compaction_enabled" => "1", "_csrf" => csrf
                })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch["streaming"]).to be(true)
    expect(patch["turn_timeout"]).to eq(300)
    expect(patch["compaction"]).to eq({ "enabled" => true, "keep_last" => 40 })
  end

  it "settings without the streaming checkbox sends streaming=false" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings", params: { "turn_timeout" => "90", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["streaming"]).to be(false)
  end

  it "the model-defaults form dispatches update_settings with the v2 platform layer" do
    app, bus = build_app
    client = login(app)
    body = client.get("/settings?s=models").body # drill: model defaults section
    expect(body).to include('name="default_model"')
    expect(body).to include('name="fallback_models"')
    csrf = csrf_from(body)
    client.post("/settings/models", params: {
                  "default_model" => "deepseek-chat", "default_provider" => "deepseek",
                  "fallback_models" => "deepseek/deepseek-chat, openai/gpt-4o-mini",
                  "utility_model" => "deepseek-chat", "_csrf" => csrf
                })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch["default_model"]).to eq("deepseek-chat")
    expect(patch["default_provider"]).to eq("deepseek")
    expect(patch["fallback_models"]).to eq(%w[deepseek/deepseek-chat openai/gpt-4o-mini])
    expect(patch["utility_model"]).to eq("deepseek-chat")
  end

  it "the edge-limits form dispatches update_settings with the edge layer only (item 33)" do
    app, bus = build_app
    client = login(app)
    body = client.get("/settings?s=edge").body # drill: edge limits section
    expect(body).to include('name="chat_rate_limit"')
    expect(body).to include('name="agent_token_ceiling"')
    csrf = csrf_from(body)
    client.post("/settings/edge", params: {
                  "chat_rate_limit" => "20", "chat_rate_window" => "60",
                  "agent_token_ceiling" => "500000", "agent_token_window" => "86400",
                  "limit_response" => "Muitas mensagens; aguarde.", "_csrf" => csrf
                })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch.keys).to eq(["edge"])
    expect(patch["edge"]["chat_rate_limit"]).to eq(20)
    expect(patch["edge"]["agent_token_ceiling"]).to eq(500_000)
    expect(patch["edge"]["limit_response"]).to eq("Muitas mensagens; aguarde.")
  end

  it "the edge-limits form writes nil for blank limits (off) without 500-ing" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    res = client.post("/settings/edge", params: { "chat_rate_limit" => "", "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(bus.last(:update_settings).payload[:patch]["edge"]["chat_rate_limit"]).to be_nil
  end

  it "the edge-limits form REJECTS an unparseable number (a typo must not silently disable a limit)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    res = client.post("/settings/edge", params: { "chat_rate_limit" => "2O", "_csrf" => csrf })
    expect(res.status).to eq(302) # red flash, not a 500
    expect(bus.last(:update_settings)).to be_nil # nothing dispatched
  end

  it "the model-defaults form does NOT touch the general-settings keys (scoped save)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/models", params: { "default_model" => "x", "_csrf" => csrf })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch.keys).to contain_exactly("default_model", "default_provider", "fallback_models",
                                          "utility_model", "thinking")
  end

  it "the model-defaults form carries the GLOBAL reasoning default (thinking)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/models", params: { "default_model" => "x", "thinking" => "off", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["thinking"]).to eq("off")
  end

  it "the per-model form parses ref|effort lines into the model_params map" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/model-params", params: {
                  "model_params" => "deepseek/deepseek-v4-flash | off\n# comment\ndeepseek-chat | low",
                  "_csrf" => csrf
                })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch["model_params"]).to eq(
      "deepseek/deepseek-v4-flash" => { "thinking" => "off" },
      "deepseek-chat" => { "thinking" => "low" }
    )
  end

  it "settings lists providers with the key MASKED (never plaintext)" do
    app, = build_app(llm_providers: [{ "api" => "deepseek", "api_key" => "sk-secret", "models" => %w[deepseek-chat] }])
    body = login(app).get("/settings?s=llm").body # drill: providers section
    expect(body).to include("deepseek")
    expect(body).to include("__OCULTO__")
    expect(body).not_to include("sk-secret")
  end

  it "saving a provider dispatches upsert_llm_provider with parsed models" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/providers", params: {
                  "api" => "openai", "base_url" => "https://api.openai.com/v1",
                  "api_key" => "sk-1", "models" => "gpt-4o, gpt-4o-mini", "_csrf" => csrf
                })
    cmd = bus.last(:upsert_llm_provider)
    expect(cmd.payload[:api]).to eq("openai")
    expect(cmd.payload[:models]).to eq(%w[gpt-4o gpt-4o-mini])
  end

  it "removing a provider dispatches delete_llm_provider" do
    app, bus = build_app(llm_providers: [{ "api" => "openai", "api_key" => "sk-1" }])
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/providers/delete", params: { "api" => "openai", "_csrf" => csrf })
    expect(bus.last(:delete_llm_provider).payload).to include(api: "openai")
  end

  # --- MCP (task 18) -------------------------------------------------------

  it "mcp lists instances with env MASKED and dispatches upsert_mcp (env by lines)" do
    app, bus = build_app(mcp_instances: [{ "name" => "tavily", "env" => { "TAVILY_KEY" => "tvly-real" } }])
    client = login(app)
    res = client.get("/mcp")
    expect(res.status).to eq(200)
    expect(res.body).to include("tavily")
    expect(res.body).to include("TAVILY_KEY=__OCULTO__")
    expect(res.body).not_to include("tvly-real")
    csrf = csrf_from(res.body)
    client.post("/mcp", params: {
                  "name" => "github", "transport" => "stdio",
                  "command" => "npx server", "enabled" => "1",
                  "env" => "GITHUB_TOKEN=ghp-1\n# comentário\nEMPTY=", "_csrf" => csrf
                })
    cmd = bus.last(:upsert_mcp)
    expect(cmd.payload[:name]).to eq("github")
    expect(cmd.payload[:enabled]).to be(true)
    expect(cmd.payload[:env]).to eq({ "GITHUB_TOKEN" => "ghp-1", "EMPTY" => "" })
  end

  it "removing an MCP instance dispatches delete_mcp" do
    app, bus = build_app(mcp_instances: [{ "name" => "tavily" }])
    client = login(app)
    csrf = csrf_from(client.get("/mcp").body)
    client.post("/mcp/delete", params: { "name" => "tavily", "_csrf" => csrf })
    expect(bus.last(:delete_mcp).payload).to include(name: "tavily")
  end

  # --- System-files (task 19) ----------------------------------------------

  it "system-files lists the global files and uses the code-editor island" do
    app, = build_app(system_files: { "HOUSE.md" => "regras da casa" })
    body = login(app).get("/system-files").body
    expect(body).to include("HOUSE.md")
    expect(body).to include("regras da casa")
    expect(body).to include('data-controller="code-editor"')
  end

  it "saving a system file dispatches write_system_file" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/system-files").body)
    client.post("/system-files", params: { "file" => "RULES.md", "content" => "# Regras", "_csrf" => csrf })
    expect(bus.last(:write_system_file).payload).to include(file: "RULES.md", content: "# Regras")
  end

  it "removing/restoring a system file dispatch their Commands" do
    app, bus = build_app(system_files: { "H.md" => "x" })
    client = login(app)
    csrf = csrf_from(client.get("/system-files").body)
    client.post("/system-files/delete", params: { "file" => "H.md", "_csrf" => csrf })
    client.post("/system-files/restore", params: { "file" => "H.md", "version" => "0", "_csrf" => csrf })
    expect(bus.last(:delete_system_file).payload).to include(file: "H.md")
    expect(bus.last(:restore_system_file).payload).to include(file: "H.md", version: "0")
  end

  # --- Chats (task 19) -----------------------------------------------------

  it "chats lists the conversations and links to the viewer" do
    sess = StoredSession.new(id: "sess-chat-000001", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-chat-000001" => sess })
    body = login(app).get("/chats").body
    expect(body).to include("/studio/sessions/sess-chat-000001")
  end

  it "empty chats shows the empty-state" do
    app, = build_app
    body = login(app).get("/chats").body
    expect(body).to include("No conversations")
  end

  # --- Overview home (T3) --------------------------------------------------

  it "overview home shows counts, an activity chart and recent conversations" do
    sess = StoredSession.new(id: "sess-home-00001", updated_at: "2026-07-21T00:00:00Z",
                             messages: [{ "role" => "user", "content" => "oi" }, { "role" => "assistant", "content" => "olá" }])
    app, = build_app(sessions: { "sess-home-00001" => sess })
    body = login(app).get("/home").body
    expect(body).to include("Overview")
    expect(body).to include("Conversations")
    expect(body).to include("active now")
    expect(body).to include("Recent conversations")
    expect(body).to include("/studio/sessions/sess-home-00001") # recent rail links to the viewer
    expect(body).to include('class="barchart"')                 # SVG activity chart
  end

  it "root redirects to the overview home" do
    app, = build_app
    res = login(app).get("/")
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to include("/studio/home")
  end

  it "the nav marks the current section active regardless of the /studio mount prefix" do
    app, = build_app
    body = login(app).get("/home").body
    expect(body).to match(%r{href="/studio/home"[^>]*aria-current="page"})
  end

  # --- Polish & parity (Stage H / task 20) ---------------------------------

  it "the app-bar has a health chip and theme switch; the html loads the theme (auto default)" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('data-theme="auto"')
    expect(body).to include('data-controller="theme"')
    expect(body).to include("runtime online")
  end

  it "the sidebar shows the environment identity chip" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('class="env-chip"')
    expect(body).to include("environment")
  end

  it "cache-busts the dist assets (?v=) so a rebuild isn't masked by the browser cache" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to match(%r{/studio/assets/dist/application\.css\?v=\d+})
    expect(body).to match(%r{/studio/assets/dist/application\.js\?v=\d+})
  end

  it "applies the cookie theme server-side (no wrong-theme flash on load)" do
    app, = build_app
    client = login(app)
    env = Rack::MockRequest.env_for("/agents", "HTTP_COOKIE" => "#{client.cookie}; insika.theme=dark")
    _, _, body = app.call(env)
    html = body.each.to_a.join
    expect(html).to include('data-theme="dark"')
  end

  it "an unexpected theme cookie falls back to auto (strict allowlist)" do
    app, = build_app
    client = login(app)
    env = Rack::MockRequest.env_for("/agents", "HTTP_COOKIE" => "#{client.cookie}; insika.theme=hackerman")
    _, _, body = app.call(env)
    expect(body.each.to_a.join).to include('data-theme="auto"')
  end

  it "the editors load the dirty-guard island (warning about leaving without saving)" do
    app, = build_app(system_files: { "H.md" => "x" })
    client = login(app)
    expect(client.get("/agents/bia").body).to include('data-controller="dirty-guard"')
    expect(client.get("/system-files").body).to include('data-controller="dirty-guard"')
    expect(client.get("/skills/new").body).to include('data-controller="dirty-guard"')
  end

  # --- G3: UI robustness — A3 (loading states) + A4 (confirm + copy) -----------

  it "destructive forms carry a data-turbo-confirm prompt (A4)" do
    fact = Insika::MemoryStore::Fact.new(key: "nome", value: "Ana", updated_at: "t")
    app, = build_app(agents: [profile("bia", prompt_files: %w[SOUL.md])],
                     data_tools: [data_tool(name: "cep")],
                     mcp_instances: [{ "name" => "tavily" }],
                     system_files: { "H.md" => "x" },
                     memory: { "bia" => { facts: [fact], notes: [] } },
                     llm_providers: [{ "api" => "openai", "api_key" => "sk-1" }])
    client = login(app)
    expect(client.get("/mcp").body).to include('action="/studio/mcp/delete"', "data-turbo-confirm=")
    expect(client.get("/tools/def/cep").body).to include("/delete", "data-turbo-confirm=")
    expect(client.get("/system-files").body).to include('action="/studio/system-files/delete"', "data-turbo-confirm=")
    expect(client.get("/settings?s=llm").body).to include('action="/studio/settings/providers/delete"', "data-turbo-confirm=")
    detail = client.get("/agents/bia").body
    expect(detail).to include("/prompts/delete", "data-turbo-confirm=")
    expect(detail).to include('/memory/forget" data-turbo-confirm=')
  end

  it "action buttons declare a data-turbo-submits-with loading label (A3)" do
    app, = build_app
    client = login(app)
    expect(client.get("/playground?agent=chef").body).to include('data-turbo-submits-with="Sending…"')
    expect(client.get("/agents/bia").body).to include("data-turbo-submits-with=")
  end

  it "the session id and tool-trace payloads load the clipboard island with a copy button (A4)" do
    sess = StoredSession.new(id: "sess-copy", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    traces = { "sess-copy" => [{ "turn" => 1, "tool" => "search_products", "call_id" => "c1",
                                 "args" => { "query" => "trufa" }, "result" => { "found" => 3 },
                                 "ms" => 40, "at" => "2026-07-16T00:00:00Z" }] }
    app, = build_app(sessions: { "sess-copy" => sess }, tool_traces: traces)
    body = login(app).get("/sessions/sess-copy").body
    expect(body).to include('data-controller="clipboard"')
    expect(body).to include('data-action="clipboard#copy"')
    expect(body).to include('data-clipboard-text-value="sess-copy"') # full id, not just the [0,16] display
    expect(body).to include('data-clipboard-target="source"')        # trace <pre> is the copy source
  end

  it "the bundle registers the clipboard controller (A4)" do
    app, = build_app
    js = Client.new(app).get("/assets/dist/application.js").body
    expect(js).to include("clipboard")
  end

  # --- Agent creation (parity: "each one creates its own BIA") -----------------

  it "creates an agent via POST /agents (dispatches create_agent) and redirects to the detail" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents").body)
    res = client.post("/agents", params: {
                        "id" => "nova", "model" => "deepseek-chat",
                        "provider" => "deepseek", "memory" => "1", "_csrf" => csrf
                      })
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/agents/nova")
    cmd = bus.last(:create_agent)
    expect(cmd.payload).to include(id: "nova", model: "deepseek-chat", provider: "deepseek", memory: true)
  end

  it "empty agents opens the creation form (authoring empty-state)" do
    app, = build_app(agents: [])
    body = login(app).get("/agents").body
    expect(body).to include("Create your first BIA")
    expect(body).to include("Create agent")
  end

  it "empty mcp shows empty-state" do
    app, = build_app
    expect(login(app).get("/mcp").body).to include("No MCP instances")
  end

  # --- Recommended restart banner ------------------------------------------

  it "lights the restart banner when touching MCP and clears it on dismiss" do
    app, = build_app
    client = login(app)
    expect(client.get("/agents").body).not_to include("Restart recommended")

    csrf = csrf_from(client.get("/mcp").body)
    client.post("/mcp", params: { "name" => "tavily", "_csrf" => csrf })
    expect(client.get("/agents").body).to include("Restart recommended")

    csrf = csrf_from(client.get("/agents").body)
    res = client.post("/restart-ack", params: { "_csrf" => csrf, "back" => "/studio/mcp" })
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/mcp")
    expect(client.get("/agents").body).not_to include("Restart recommended")
  end

  it "removing an MCP also lights the restart banner" do
    app, = build_app(mcp_instances: [{ "name" => "tavily" }])
    client = login(app)
    csrf = csrf_from(client.get("/mcp").body)
    client.post("/mcp/delete", params: { "name" => "tavily", "_csrf" => csrf })
    expect(client.get("/agents").body).to include("Restart recommended")
  end

  it "restart-ack does not open-redirect (external back is ignored)" do
    app, = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents").body)
    res = client.post("/restart-ack", params: { "_csrf" => csrf, "back" => "https://evil.com" })
    expect(res.headers["location"]).to eq("/studio/agents")
  end

  # --- Tasks & Approvals (§12 G5) ------------------------------------------

  def task(id: "t1", status: :running, session_id: "s1", executions: [])
    TaskDouble.new(id: id, status: status, command: { "type" => "send_message" },
                   session_id: session_id, executions: executions, updated_at: "2026-07-21T00:00:00Z")
  end

  def pending(id: "p1", task_id: "t1", tool: "charge", status: :pending)
    StudioPendingRow.new(id: id, task_id: task_id, turn: 1, tool: tool,
                      args: { "amount" => 10 }, status: status, requested_at: "2026-07-21T00:00:00Z")
  end

  it "lists tasks with a status pill (GET /tasks)" do
    app, = build_app(tasks: { "t1" => task(id: "t1", status: :running) })
    res = login(app).get("/tasks")
    expect(res.status).to eq(200)
    expect(res.body).to include("t1")
    expect(res.body).to include("running")
  end

  it "shows the tasks empty-state when there are none" do
    app, = build_app
    expect(login(app).get("/tasks").body).to include("No tasks yet")
  end

  it "renders a task detail with command + operator controls (GET /tasks/:id)" do
    exec = ExecDouble.new(attempt: 1, started_at: "t0", finished_at: "t1", outcome: "failed", error: "boom")
    app, = build_app(tasks: { "t1" => task(executions: [exec]) })
    res = login(app).get("/tasks/t1")
    expect(res.status).to eq(200)
    expect(res.body).to include("send_message")     # the command
    expect(res.body).to include("/studio/tasks/t1/pause")
    expect(res.body).to include("/studio/tasks/t1/cancel")
    expect(res.body).to include("boom")             # the execution error
  end

  it "404s on a task that doesn't exist" do
    app, = build_app
    expect(login(app).get("/tasks/ghost").status).to eq(404)
  end

  it "shows a task's pending approvals inline on the detail page" do
    app, = build_app(tasks: { "t1" => task }, pendings: [pending(tool: "refund_order")])
    res = login(app).get("/tasks/t1")
    expect(res.body).to include("refund_order")
    expect(res.body).to include("/studio/approvals/p1")
  end

  it "shows the latest checkpoint metrics when present" do
    app, = build_app(
      tasks: { "t1" => task },
      checkpoints: { "t1" => StudioCheckpointRow.new(turn: 3, messages: [1, 2], completed_side_effects: [1], created_at: "t0") }
    )
    res = login(app).get("/tasks/t1")
    expect(res.body).to include("Latest checkpoint")
    expect(res.body).not_to include("No checkpoint recorded")
  end

  %i[pause resume cancel].each do |action|
    it "POST /tasks/:id/#{action} dispatches :#{action}_task via the bus" do
      app, bus = build_app(tasks: { "t1" => task })
      client = login(app)
      csrf = csrf_from(client.get("/tasks/t1").body)
      res = client.post("/tasks/t1/#{action}", params: { "_csrf" => csrf })
      expect(res.status).to eq(302)
      expect(res.headers["location"]).to eq("/studio/tasks/t1")
      cmd = bus.last(:"#{action}_task")
      expect(cmd).not_to be_nil
      expect(cmd.payload[:task_id]).to eq("t1")
      expect(cmd.meta[:transport]).to eq(:studio)
    end
  end

  it "blocks a task control POST without CSRF (403)" do
    app, bus = build_app(tasks: { "t1" => task })
    client = login(app)
    client.get("/tasks/t1") # session, but POST omits _csrf
    expect(client.post("/tasks/t1/cancel").status).to eq(403)
    expect(bus.types).not_to include(:cancel_task)
  end

  it "lists pending approvals across tasks with their task status (GET /approvals)" do
    app, = build_app(tasks: { "t1" => task(status: :waiting) },
                     pendings: [pending(tool: "charge_card")])
    res = login(app).get("/approvals")
    expect(res.status).to eq(200)
    expect(res.body).to include("charge_card")
    expect(res.body).to include("waiting")
  end

  it "shows the approvals empty-state when nothing is pending" do
    app, = build_app
    expect(login(app).get("/approvals").body).to include("No pending approvals")
  end

  it "POST /approvals/:pid approves via :approve_action (operator=studio)" do
    app, bus = build_app(pendings: [pending])
    client = login(app)
    csrf = csrf_from(client.get("/approvals").body)
    res = client.post("/approvals/p1", params: { "decision" => "approved", "_csrf" => csrf })
    expect(res.status).to eq(302)
    cmd = bus.last(:approve_action)
    expect(cmd.payload).to include(pending_id: "p1", decision: "approved", operator: "studio")
  end

  it "POST /approvals/:pid honours a 'rejected' decision" do
    app, bus = build_app(pendings: [pending])
    client = login(app)
    csrf = csrf_from(client.get("/approvals").body)
    client.post("/approvals/p1", params: { "decision" => "rejected", "_csrf" => csrf })
    expect(bus.last(:approve_action).payload[:decision]).to eq("rejected")
  end

  it "an unknown decision falls back to 'approved' (never dispatches a junk decision)" do
    app, bus = build_app(pendings: [pending])
    client = login(app)
    csrf = csrf_from(client.get("/approvals").body)
    client.post("/approvals/p1", params: { "decision" => "sudo", "_csrf" => csrf })
    expect(bus.last(:approve_action).payload[:decision]).to eq("approved")
  end

  it "redirects an approval back to a safe local path, ignoring an external back" do
    app, = build_app(pendings: [pending])
    client = login(app)
    csrf = csrf_from(client.get("/approvals").body)
    res = client.post("/approvals/p1",
                      params: { "decision" => "approved", "back" => "https://evil.com", "_csrf" => csrf })
    expect(res.headers["location"]).to eq("/studio/approvals")
  end

  it "redirects an approval to the task detail when back points there" do
    app, = build_app(tasks: { "t1" => task }, pendings: [pending])
    client = login(app)
    csrf = csrf_from(client.get("/tasks/t1").body)
    res = client.post("/approvals/p1",
                      params: { "decision" => "approved", "back" => "/studio/tasks/t1", "_csrf" => csrf })
    expect(res.headers["location"]).to eq("/studio/tasks/t1")
  end

  it "surfaces a Command error as a red flash (Validation/NotFound → not a 500)" do
    bus = Class.new(BusDouble) do
      def dispatch(command)
        raise Insika::NotFoundError, "task not found" if command.type == :cancel_task

        super
      end
    end.new([])
    app = Class.new(Studio::App)
    app.configure(command_bus: bus, profile_source: ProfileSourceDouble.new([profile("bia")]),
                  event_stream: nil, config: { admin_token: "s3cret" },
                  task_store: TaskStoreDouble.new({ "t1" => task }), session_secret: "x" * 64)
    client = login(app)
    csrf = csrf_from(client.get("/tasks/t1").body)
    res = client.post("/tasks/t1/cancel", params: { "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(client.get("/tasks/t1").body).to include("task not found") # flash, not a crash
  end
end
