# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

# Studio — Roda app mounted under /studio. Exercises cookie auth
# (fail-closed), CSRF on POSTs, strict CSP, serving of versioned assets and
# the login/agents/playground pages. Doubles in place of the runtime: the Studio only
# READS the ProfileSource and dispatches Commands on the bus (never writes to a store
# directly) — the same surface as Server::App.
RSpec.describe Studio::App do
  SessionDouble = Struct.new(:id)
  StoredSession = Struct.new(:id, :messages, :vars, :updated_at, :briefing, keyword_init: true)

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

    def registered?(_type) = true
    def last(type) = dispatched.reverse.find { |c| c.type == type }
    def types = dispatched.map(&:type)
  end

  # RFC-0031 C8: wraps a REAL CommandBus (executes the customer commands) and
  # records every dispatch for assertion. NB: distinct name — RSpec constants
  # leak to top-level Object, so a shared name would clobber.
  StudioRecordingBus = Struct.new(:real, :dispatched) do
    def initialize(real) = super(real, [])
    def register(*args) = real.register(*args)
    def registered?(type) = real.registered?(type)
    def dispatch(cmd) = (dispatched << cmd; real.dispatch(cmd))
    def last(type) = dispatched.reverse.find { |c| c.type == type }
  end

  # ProfileSource duck-type: `all` (list) + `ids` + `fetch`.
  ProfileSourceDouble = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
    def fetch(id) = profiles.find { |p| p.id == id }
  end

  # read stores (only what the pages consume).
  # body/triggers/companions: real catalog skills expose them (the drill editor and
  # skill_source's frontmatter reconstruction read them).
  SkillEntry = Struct.new(:name, :description, :body, :triggers, :companions, keyword_init: true)
  AgentFileStoreDouble = Struct.new(:files) do # files: { [agent, name] => content }
    def read(agent, name) = files[[agent, name.to_s]]
    def versions(_agent, _name) = []
  end
  # agent: — a skill resolves per agent (an override wins for its holder). The
  # doubles carry the agent scope as { [agent, name] => … }, mirroring the store's
  # two-argument shape.
  SkillCatalogDouble = Struct.new(:skills, :own) do # own: { [agent, name] => SkillEntry }
    def all(agent: nil) = agent.nil? ? skills : skills.map { |s| scoped(agent, s.name) || s }
    def find(name, agent: nil) = scoped(agent, name) || skills.find { |s| s.name == name.to_s }
    def scoped(agent, name) = agent && (own || {})[[agent, name.to_s]]
  end
  SkillStoreDouble = Struct.new(:store, :own) do # store: { name => content }; own: { [agent, name] => content }
    def names(agent: nil) = agent.nil? ? store.keys : (own || {}).keys.select { |a, _| a == agent }.map(&:last)
    def get(name, agent: nil) = agent.nil? ? store[name.to_s] : (own || {})[[agent, name.to_s]]
    def agents = (own || {}).keys.map(&:first).uniq.sort
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

  # tasks/approvals read stores. Only the surface the pages consume.
  TaskDouble = Struct.new(:id, :status, :command, :session_id, :executions, :updated_at,
                          :timing, keyword_init: true)
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
              tools_allow: %w[menu calc], skills: %w[pedido], skills_eager: nil, prompt_files: [],
              funnel: nil, followup: nil)
    Insika::AgentProfile.build(id: id, model: model, provider: provider,
                                memory: memory, tools_allow: tools_allow,
                                skills: skills, skills_eager: skills_eager, prompt_files: prompt_files,
                                funnel: funnel, followup: followup)
  end

  # RFC-0033 C10: the follow-up page reads REAL stores (records + contact
  # cells over one in-memory backend), like the funnel page does.
  FOLLOWUP_DECL = {
    "arm" => "schedule",
    "policy" => { "quiet_hours" => { "timezone" => "America/Sao_Paulo",
                                     "start" => "21:30", "end" => "09:00" },
                  "max_frequency" => "2/24h",
                  "cancel_keywords" => ["não quero mais contato"],
                  "silence_after_sends" => 3 }
  }.freeze

  def seed_followups(records)
    return nil unless records

    backend = Insika::Stores::Memory.new
    store = Insika::FollowupStore.new(store: backend)
    contacts = Insika::ContactStore.new(store: backend)
    records.each do |r|
      store.create(tenant: r[:tenant] || "platform", agent: r[:agent], customer: r[:customer],
                   session_id: r[:session_id], at: r[:at], reason: r[:reason],
                   arm: r[:arm] || "schedule", id: r[:id], now: r[:now] || Time.iso8601("2026-08-14T12:00:00Z"))
      case r[:status]
      when "fired" then store.transition_fired(id: r[:id], task_id: "t-#{r[:id]}",
                                               now: r[:now] || Time.iso8601("2026-08-14T12:00:00Z"))
      when "cancelled" then store.cancel(id: r[:id])
      when "blocked" then store.block(id: r[:id], reason: r[:blocked_reason] || "frequency")
      end
      # contact cells for the opt-out fold (review fix: the fold is per
      # (tenant, customer) — seed the cells the arms' customers own)
      Array(r[:contacts]).each do |c|
        contacts.set_revoked(tenant: c[:tenant] || "platform", customer: c[:customer]) if c[:state] == "revoked"
        contacts.set_granted(tenant: c[:tenant] || "platform", customer: c[:customer]) if c[:state] == "granted"
      end
    end
    { followup_store: store, contact_store: contacts }
  end

  # RFC-0034 C7: the Facts (wiki) page reads a REAL ProposalStore over an
  # in-memory backend — the same store the engine writes through.
  def seed_facts(rows)
    return nil unless rows

    store = Insika::ProposalStore.new(store: Insika::Stores::Memory.new)
    rows.each do |r|
      store.create(tenant: r[:tenant] || "acme", customer: r[:customer] || "c-1",
                   session_ref: r[:session_ref], key: r[:key], value: r[:value],
                   confidence: r[:confidence], evidence: r[:evidence] || [], id: r[:id])
      case r[:status]
      when "approved" then store.approve(id: r[:id], operator: "studio")
      when "rejected" then store.reject(id: r[:id], operator: "studio", note: r[:note])
      when "dismissed" then store.dismiss(id: r[:id])
      when "stale" then store.mark_stale(id: r[:id], current_value: r[:current_value])
      end
    end
    store
  end

  def build_app(admin_token: "s3cret", agents: [profile("bia"), profile("chef")],
                agent_files: {}, skills: [SkillEntry.new(name: "pedido", description: "faz pedido")],
                stored_skills: {}, own_skills: {}, tools: [SkillEntry.new(name: "menu", description: "cardápio")],
                data_tools: [], raw_data_tools: {}, memory: {}, sessions: {}, settings: nil, llm_providers: [],
                mcp_instances: [], system_files: {}, tool_traces: {}, context_traces: {},
                 tasks: {}, pendings: [], checkpoints: {}, refinement_runs: [], goldens: [], event_stream: nil,
                 outcomes: [], cache_series: {}, funnel_cells: nil, budget: nil, followup_seed: nil,
                 proposal_store: nil, harvest_store: nil, harvest_criterion: nil,
                 negative_list: nil)
    bus = BusDouble.new([])
    app = Class.new(Studio::App)
    # config stores: REAL over an in-memory ConfigStore (the Studio reads
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
    # REAL ToolStore: the authoring page reads from it; writes via the bus.
    tool_store = Insika::ToolStore.new(config_store: cfg)
    data_tools.each { |d| tool_store.write(d) }
    # Records written straight to the ConfigStore, BYPASSING validation — the only way to
    # seed a definition the engine no longer accepts (a legacy one). The editor has to
    # open those: it is where they get fixed.
    raw_data_tools.each do |name, definition|
      cfg.put("tools", name, { "definition" => definition, "updated_at" => "2026-01-01T00:00:00Z", "history" => [] })
    end
    # Eval cases: the REAL store, seeded through its own validating
    # write — the page must be exercised against what the loader accepts.
    golden_store = Insika::GoldenStore.new(config_store: cfg)
    goldens.each { |g| golden_store.write(g) }
    # refinement runs, seeded through the REAL store's own API
    # (create + complete) so the page is exercised against the record shape the
    # collector actually writes. refinement_runs: [{ agent:, findings: [...] }, …].
    refinement_store = Insika::RefinementStore.new(store: Insika::Stores::Memory.new)
    refinement_runs.each_with_index do |run, i|
      row = refinement_store.create(agent_id: run[:agent], window: run[:window] || { "last_sessions" => 200 },
                                    at: format("2026-08-0%dT10:00:00Z", i + 1))
      refinement_store.complete(row.id, findings: run[:findings] || [])
    end
    # REAL ToolTraceStore (debug): the session view reads from it.
    trace_store = Insika::ToolTraceStore.new(store: Insika::Stores::Memory.new)
    tool_traces.each { |sid, entries| entries.each { |e| trace_store.record(session_id: sid, entry: e) } }
    # REAL ContextTraceStore: the session view's breakdown card.
    ctx_trace_store = Insika::ContextTraceStore.new(store: Insika::Stores::Memory.new)
    context_traces.each { |sid, entries| entries.each { |e| ctx_trace_store.record(session_id: sid, entry: e) } }
    # REAL CacheSeriesStore (RFC-0030): the agent-detail cache tab.
    series_store = Insika::CacheSeriesStore.new(store: Insika::Stores::Memory.new)
    cache_series.each { |agent, entries| entries.each { |e| series_store.record(agent: agent, entry: e) } }
    app.configure(
      command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
      event_stream: event_stream, config: { admin_token: admin_token },
      agent_file_store: AgentFileStoreDouble.new(agent_files),
      # own_skills: { [agent, name] => "<SKILL.md>" } — the per-agent specializations.
      skill_store: SkillStoreDouble.new(stored_skills, own_skills),
      skill_catalog: SkillCatalogDouble.new(
        skills,
        # The catalog resolves the same NAME to the agent's own body: the store position
        # is the identity, so the entry keeps the bare shared name.
        own_skills.each_with_object({}) { |((a, n), c), acc| acc[[a, n]] = SkillEntry.new(name: n, description: "d", body: c) }
      ),
      tool_catalog: ToolCatalogDouble.new(tools),
      tool_store: tool_store,
      memory_store: MemoryStoreDouble.new(memory),
      session_store: SessionStoreDouble.new(sessions),
      settings_store: settings_store, llm_provider_store: provider_store,
      mcp_store: mcp_store, system_file_store: system_file_store,
      tool_trace_store: trace_store, context_trace_store: ctx_trace_store,
      cache_series_store: series_store,
      task_store: TaskStoreDouble.new(tasks),
      pending_action_store: PendingStoreDouble.new(pendings),
      checkpoint_store: CheckpointStoreDouble.new(checkpoints),
       refinement_store: refinement_store, golden_store: golden_store,
        outcome_store: seed_outcomes(outcomes),
        funnel_store: seed_funnel(funnel_cells),
        budget_ledger: seed_budget(budget),
        # RFC-0033 C10: the Follow-ups page reads the real stores.
        followup_store: seed_followups(followup_seed)&.fetch(:followup_store),
        contact_store: seed_followups(followup_seed)&.fetch(:contact_store),
        # RFC-0034 C7: the Facts (wiki) page reads the real proposal store.
        proposal_store: proposal_store,
        # RFC-0035 C11: the Harvest page reads the harvest store + the two
        # pre-registered artifacts directly.
        harvest_store: harvest_store, harvest_criterion: harvest_criterion,
        negative_list: negative_list,
        session_secret: "x" * 64
    )
     [app, bus]
   end

   def seed_funnel(cells)
     return nil unless cells

     store = Insika::FunnelStore.new(store: Insika::Stores::Memory.new)
     cells.each do |cell|
       store.add(tenant: cell[:tenant], agent: cell[:agent], at: cell[:at],
                 counts: cell[:counts])
     end
     store
   end

   def seed_budget(rows)
     return nil unless rows

     ledger = Insika::BudgetLedger.new(store: Insika::Stores::Memory.new)
     rows.each { |row| ledger.add(tenant: row[:tenant], agent: row[:agent], by: row[:by]) }
     ledger
   end

   def seed_outcomes(rows)
     store = Insika::OutcomeStore.new(store: Insika::Stores::Memory.new)
     rows.each { |row| store.create(**row) }
     store
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

  it "playground GET suggests recent sessions in a datalist combobox" do
    sessions = {
      "s-recent" => StoredSession.new(id: "s-recent",
                                       messages: [{ "role" => "user", "content" => "oi" }],
                                       vars: nil, updated_at: "2026-08-14T10:00:00Z"),
      "s-older" => StoredSession.new(id: "s-older", messages: [], vars: nil,
                                     updated_at: "2026-08-13T10:00:00Z")
    }
    app, = build_app(sessions: sessions)
    body = login(app).get("/playground").body
    expect(body).to include('<datalist id="recent-sessions">')
    expect(body).to include(%(<option value="s-recent" label="))
    expect(body).to include(%(<option value="s-older" label="))
  end

  it "playground keeps the open session in the combobox even when it fell off the recents" do
    sessions = {}
    9.times do |i|
      sessions["s-new-#{i}"] = StoredSession.new(id: "s-new-#{i}", messages: [], vars: nil,
                                                 updated_at: "2026-08-1#{i}T10:00:00Z")
    end
    sessions["s-open"] = StoredSession.new(id: "s-open", messages: [], vars: nil,
                                           updated_at: "2026-08-01T10:00:00Z")
    app, = build_app(sessions: sessions)
    body = login(app).get("/playground?session_id=s-open").body
    expect(body).to include(%(<option value="s-open" label="))
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

  it "playground pins the model on a NEW conversation via create_session" do
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

  it "playground echoes the just-sent message as a user bubble on the next GET" do
    app, = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: { "agent" => "chef", "session_id" => "s1",
                                          "message" => "olá-echo-42", "_csrf" => csrf })
    body = client.get("/playground?agent=chef&session_id=s1").body
    expect(body).to include("olá-echo-42")
    expect(body).to include('class="msg user"')
  end

  it "playground GET renders the session's persisted transcript as bubbles" do
    sess = StoredSession.new(id: "s1", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "pergunta-persistida" },
                                        { "role" => "assistant", "content" => "resposta-persistida" }])
    app, = build_app(sessions: { "s1" => sess })
    body = login(app).get("/playground?agent=chef&session_id=s1").body
    expect(body).to include("pergunta-persistida")
    expect(body).to include("resposta-persistida")
    expect(body).to include('data-controller="markdown"') # assistant bubble renders Markdown
  end

  it "the app-bar has the skills and tools links" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('href="/studio/skills"')
    expect(body).to include('href="/studio/tools"')
  end

  # Agents (detail) —/17 ----------------------------------------

   it "renders the agent detail with config, prompts, skills, memory, outcomes and history" do
     app, = build_app
     res = login(app).get("/agents/bia")
     expect(res.status).to eq(200)
     %w[config prompts skills memory outcomes history].each { |a| expect(res.body).to include("id=\"#{a}\"") }
    expect(res.body).to include('name="model"')
  end

   it "the prompts section is a drill: nothing selected shows the pick-a-file state" do
     app, = build_app
     body = login(app).get("/agents/bia").body
     expect(body).to include("Pick a prompt file on the left")
     expect(body).not_to include('data-controller="code-editor"')
   end

   it "GET prompts/new opens the create form in the drill" do
     app, = build_app
     body = login(app).get("/agents/bia/prompts/new").body
     expect(body).to include("New prompt file")
     expect(body).to include('name="file"')
     expect(body).to include('data-controller="code-editor"')
   end

   it "GET prompts/:file opens that file's editor, versions and remove action" do
     app, = build_app(agents: [profile("bia", prompt_files: %w[IDENTITY.md])],
                      agent_files: { ["bia", "IDENTITY.md"] => "# Eu" })
     body = login(app).get("/agents/bia/prompts/IDENTITY.md").body
     expect(body).to include("IDENTITY.md")
     expect(body).to include("# Eu")
     expect(body).to include("/prompts/delete")
     expect(body).to include('data-controller="code-editor"')
     expect(body).to include("Save prompt")
   end

   it "the prompt file list links into the drill routes" do
     app, = build_app(agents: [profile("bia", prompt_files: %w[IDENTITY.md SOUL.md])])
     body = login(app).get("/agents/bia").body
     expect(body).to include("/agents/bia/prompts/IDENTITY.md")
     expect(body).to include("/agents/bia/prompts/SOUL.md")
   end

   it "the agents grid shows the last outcome per agent" do
     app, = build_app(outcomes: [
                        { tenant: "platform", agent: "bia", outcome: "conversion", value: 129.9 }
                      ])
     body = login(app).get("/agents").body
     expect(body).to include("conversion")
     expect(body).to include("R$ 129.90")
   end

   it "the agent detail shows the per-day outcome series for that agent only" do
     app, = build_app(outcomes: [
                        { tenant: "platform", agent: "bia", outcome: "conversion", value: 100,
                          at: Time.utc(2026, 8, 12) },
                        { tenant: "platform", agent: "bia", outcome: "deflected",
                          at: Time.utc(2026, 8, 12) },
                        { tenant: "platform", agent: "chef", outcome: "escalation",
                          at: Time.utc(2026, 8, 11) }
                      ])
     body = login(app).get("/agents/bia").body
     expect(body).to include("id=\"outcomes\"")
     expect(body).to include("2026-08-12")
     expect(body).to include("conversion ×1")
     expect(body).to include("deflected ×1")
     expect(body).to include("R$ 100.00")
     expect(body).not_to include("escalation")
   end

   it "404 on the detail of a nonexistent agent" do
    app, = build_app
    expect(login(app).get("/agents/nao-existe").status).to eq(404)
  end

  # RFC-0030 C9 — the agent detail's cache tab (per-AGENT prefix cache-hit
  # series, read from the CacheSeriesStore; nil store = the empty state).
  describe "the agent detail cache tab (RFC-0030)" do
    it "renders the cache card with hit % and the invalidation reason when the store has entries" do
      app, = build_app(cache_series: {
                         "bia" => [{ at: "2026-08-15T10:00:00Z", turn: 2, hit_pct: 83,
                                     cached_tokens: 21_845, prompt_tokens: 26_319,
                                     invalidation_reason: "memory" }]
                       })
      body = login(app).get("/agents/bia").body
      expect(body).to include("id=\"cache\"")
      expect(body).to include("83% cached")
      expect(body).to include("21845/26319 tokens")
      expect(body).to include("broke: memory")
      expect(body).not_to include("No turns recorded.")
    end

    it "without a store the tab renders 'No turns recorded.' and nothing raises" do
      app, = build_app
      body = login(app).get("/agents/bia").body
      expect(body).to include("id=\"cache\"")
      expect(body).to include("No turns recorded.")
    end

    it "the series is per agent: chef's entries never appear on bia's tab" do
      app, = build_app(cache_series: {
                         "chef" => [{ at: "2026-08-15T10:00:00Z", turn: 1, hit_pct: 10,
                                      cached_tokens: 1, prompt_tokens: 10, invalidation_reason: nil }]
                       })
      body = login(app).get("/agents/bia").body
      expect(body).to include("No turns recorded.")
      expect(body).not_to include("10% cached")
    end

    it "a hit_pct of nil renders the em dash, not a fake zero" do
      app, = build_app(cache_series: {
                         "bia" => [{ at: "2026-08-15T10:00:00Z", turn: 1, hit_pct: nil,
                                     cached_tokens: 0, prompt_tokens: 0, invalidation_reason: nil }]
                       })
      body = login(app).get("/agents/bia").body
      expect(body).to include("—")
      expect(body).not_to include("0% cached")
    end
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

  # the third tool-execution bound sits in the same form as the two
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

  # config v2 surfacing -------------------------------------------

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

  # RFC-0036 C2: `corpora` is DSL/pack data (docs/domain.md), NOT a form
  # field — the config form must carry the existing value through, or a save
  # wipes the removability knob (the halt_when defect class: a shallow
  # merge over a form that does not render the key).
  it "config save preserves guardrails.corpora (the removability knob survives the UI)" do
    agent = Insika::AgentProfile.build(id: "bia", model: "m",
                                       guardrails: { "corpora" => { "languages" => ["en"] } })
    app, bus = build_app(agents: [agent])
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "_csrf" => csrf })
    guardrails = bus.last(:update_agent).payload[:guardrails]
    expect(guardrails["corpora"]).to eq("languages" => ["en"])
  end

  # --- The full config surface: EVERY profile field is editable here ---------
  # The pack import is one door; the config form is the other. Each feature's
  # block round-trips: the form renders the current value, the patch parses it
  # back into the same deep-stringified shape the engine reads.

  describe "the agent config edits every profile field" do
    def config_post(client, params)
      csrf = csrf_from(client.get("/agents/bia").body)
      client.post("/agents/bia/config", params: params.merge("_csrf" => csrf))
    end

    it "grounding: mode, matcher sku and name keys" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x", "grounding_mode" => "enforce",
                          "grounding_matcher_sku" => "sku:", "grounding_name_keys" => "product, name")
      expect(bus.last(:update_agent).payload[:grounding]).to eq(
        "mode" => "enforce", "matcher" => { "sku" => "sku:", "name_keys" => %w[product name] }
      )

      config_post(client, "model" => "x", "grounding_mode" => "")
      expect(bus.last(:update_agent).payload[:grounding]).to be_nil
    end

    it "funnel: stages per line, primary, window and the advance_on JSON" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x",
                          "funnel_stages" => "greeted\nqualified\npaid",
                          "funnel_primary" => "paid",
                          "funnel_attribution_window" => "72h",
                          "funnel_advance_on" => '{ "pix_paid": "paid" }')
      expect(bus.last(:update_agent).payload[:funnel]).to eq(
        "stages" => %w[greeted qualified paid], "primary" => "paid",
        "attribution_window" => "72h", "advance_on" => { "pix_paid" => "paid" }
      )

      config_post(client, "model" => "x", "funnel_stages" => "")
      expect(bus.last(:update_agent).payload[:funnel]).to be_nil # blank stages = no funnel
    end

    it "followup: arm, quiet hours, keywords, frequency and silence" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x", "followup_arm" => "schedule",
                          "followup_tz" => "America/Sao_Paulo",
                          "followup_quiet_start" => "21:30", "followup_quiet_end" => "09:00",
                          "followup_max_frequency" => "2/24h",
                          "followup_cancel_keywords" => "não quero mais contato",
                          "followup_silence_after_sends" => "3")
      expect(bus.last(:update_agent).payload[:followup]).to eq(
        "arm" => "schedule",
        "policy" => { "quiet_hours" => { "timezone" => "America/Sao_Paulo",
                                         "start" => "21:30", "end" => "09:00" },
                      "max_frequency" => "2/24h",
                      "cancel_keywords" => ["não quero mais contato"],
                      "silence_after_sends" => 3 }
      )

      config_post(client, "model" => "x", "followup_arm" => "")
      expect(bus.last(:update_agent).payload[:followup]).to be_nil # blank arm = off
    end

    it "distill: the enabled switch + the forge's knobs; blank prompt drops the key" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x", "distill_enabled" => "1",
                          "distill_idle_hours" => "12", "distill_min_messages" => "5",
                          "distill_max_proposals" => "3", "distill_model" => "deepseek-v4-flash",
                          "distill_prompt" => "what counts")
      expect(bus.last(:update_agent).payload[:distill]).to eq(
        "enabled" => true, "idle_hours" => 12, "min_messages" => 5,
        "max_proposals" => 3, "model" => "deepseek-v4-flash", "prompt" => "what counts"
      )

      # unchecked = explicit off, with the other knobs preserved
      config_post(client, "model" => "x", "distill_idle_hours" => "12")
      expect(bus.last(:update_agent).payload[:distill]).to eq("enabled" => false, "idle_hours" => 12)
    end

    it "harvest: the enabled switch, the miner block and the negative list JSON" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x", "harvest_enabled" => "1",
                          "harvest_idle_hours" => "48",
                          "harvest_miner_model" => "deepseek-v4-flash",
                          "harvest_miner_window" => "100",
                          "harvest_miner_max_proposals" => "5",
                          "harvest_miner_budget_tokens" => "20000",
                          "harvest_negative_list" => '[ { "rule": "no-competitor-prices", "pattern": "concorrente" } ]')
      expect(bus.last(:update_agent).payload[:harvest]).to eq(
        "enabled" => true, "idle_hours" => 48,
        "miner" => { "model" => "deepseek-v4-flash", "window" => { "last_sessions" => 100 },
                     "max_proposals" => 5, "budget" => { "tokens" => 20_000 } },
        "negative_list" => [{ "rule" => "no-competitor-prices", "pattern" => "concorrente" }]
      )
    end

    it "refinement: mode, window, findings cap, files, proposers and budget" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x", "refinement_mode" => "propose",
                          "refinement_window" => "50", "refinement_max_findings" => "5",
                          "refinement_files" => "IDENTITY.md",
                          "refinement_proposers" => "deepseek/deepseek-v4-flash",
                          "refinement_budget_tokens" => "30000",
                          "refinement_auto_apply_max_edits" => "2")
      expect(bus.last(:update_agent).payload[:refinement]).to eq(
        "mode" => "propose", "window" => { "last_sessions" => 50 }, "max_findings" => 5,
        "files" => ["IDENTITY.md"], "proposers" => ["deepseek/deepseek-v4-flash"],
        "budget" => { "tokens" => 30_000 }, "auto_apply_max_edits" => 2
      )
    end

    it "budget, reliability, routes, outputs, metadata, alerts and edge_stream" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x",
                          "budget_daily" => "100000", "budget_monthly" => "2000000",
                          "budget_soft" => "1", "budget_alert_at" => "0.9",
                          "reliability_retries" => "2", "reliability_backoff" => "exponential",
                          "reliability_timeout" => "30", "reliability_fallback" => "openai/gpt-4o-mini",
                          "reliability_breaker_after" => "10", "reliability_breaker_within" => "60",
                          "reliability_breaker_cooldown" => "300",
                          "routes" => '{ "shopping": "browse", "default": "shopping" }',
                          "outputs" => '{ "image": { "model": "gpt-image-1" } }',
                          "metadata" => '{ "store_id": "acme" }',
                          "alerts_webhook" => "https://ops.example.com/hook",
                          "edge_thinking" => "1")
      payload = bus.last(:update_agent).payload
      expect(payload[:budget]).to eq("daily" => 100_000, "monthly" => 2_000_000,
                                     "soft" => true, "alert_at" => 0.9)
      expect(payload[:reliability]).to eq(
        "retries" => 2, "backoff" => "exponential", "timeout" => 30,
        "fallback" => ["openai/gpt-4o-mini"],
        "circuit_breaker" => { "after" => 10, "within" => 60, "cooldown" => 300 }
      )
      expect(payload[:routes]).to eq("shopping" => "browse", "default" => "shopping")
      expect(payload[:outputs]).to eq("image" => { "model" => "gpt-image-1" })
      expect(payload[:metadata]).to eq("store_id" => "acme")
      expect(payload[:alerts]).to eq("webhook" => "https://ops.example.com/hook")
      expect(payload[:edge_stream]).to eq("thinking" => true, "intermediate" => false)
    end

    it "the advanced lists: subagents/capabilities/briefing/policies (symbols)/declares; blank allowlists = nil (all)" do
      app, bus = build_app
      client = login(app)
      config_post(client, "model" => "x",
                          "subagents" => "order-agent, security",
                          "capabilities" => "promotions",
                          "tools_deferred" => "search",
                          "briefing_fields" => "customer_name, wishlist",
                          "approvals_required" => "send_coupon",
                          "policies" => "tool_allowlist, skill_allowlist",
                          "prompt_refs" => "base",
                          "capabilities_declared" => "promotions, human_handoff",
                          "skills_eager" => "all")
      payload = bus.last(:update_agent).payload
      expect(payload[:subagents]).to eq(%w[order-agent security])
      expect(payload[:capabilities]).to eq(["promotions"])
      expect(payload[:tools_deferred]).to eq(["search"])
      expect(payload[:briefing_fields]).to eq(%w[customer_name wishlist])
      expect(payload[:approvals_required]).to eq(["send_coupon"])
      expect(payload[:policies]).to eq(%i[tool_allowlist skill_allowlist])
      expect(payload[:prompt_refs]).to eq(["base"])
      expect(payload[:capabilities_declared]).to eq(%w[promotions human_handoff])
      expect(payload[:skills_eager]).to be(true) # "all"

      config_post(client, "model" => "x", "context_providers" => "", "workflows_allow" => "")
      payload = bus.last(:update_agent).payload
      expect(payload[:context_providers]).to be_nil # nil = all
      expect(payload[:workflows_allow]).to be_nil
    end

    it "malformed JSON in a config block is a red flash, never a dispatch" do
      app, bus = build_app
      client = login(app)
      res = config_post(client, "model" => "x", "routes" => "{ not json")
      expect(res.status).to eq(302)
      expect(client.get(res.headers["location"]).body).to include("invalid JSON")
      expect(bus.types).not_to include(:update_agent)
    end
  end

  # --- The loops tab: automatic loops with a manual trigger per agent --------

  describe "the automatic-loops tab" do
    def loops_app(agent)
      build_app(agents: [agent])
    end

    it "shows the Run buttons only for the loops the agent declares" do
      agent = Insika::AgentProfile.build(
        id: "bia", model: "m", memory: true,
        distill: { "enabled" => true, "idle_hours" => 6 },
        harvest: { "enabled" => true, "idle_hours" => 24 },
        refinement: { "mode" => "report" }
      )
      app, = loops_app(agent)
      body = login(app).get("/agents/bia#loops").body

      expect(body).to include("Run distillation now")
      expect(body).to include("Run harvest now")
      expect(body).to include("Run refinement now")
      expect(body).to include("idle 6h")
      expect(body).to include("idle 24h")
    end

    it "a declared-off loop shows no Run button" do
      app, = build_app # bia has no distill/harvest/refinement
      body = login(app).get("/agents/bia").body
      expect(body).not_to include("Run distillation now")
      expect(body).not_to include("Run harvest now")
    end

    it "POST distill runs the due sessions of THIS agent" do
      old = (Time.now.utc - 24 * 3600).iso8601
      sessions = {
        "s-bia" => StoredSession.new(id: "s-bia",
                                     messages: Array.new(5) { { "role" => "user", "content" => "hi" } },
                                     vars: { "agent" => "bia", "customer" => "c-1" },
                                     updated_at: old, briefing: nil),
        "s-chef" => StoredSession.new(id: "s-chef",
                                      messages: Array.new(5) { { "role" => "user", "content" => "hi" } },
                                      vars: { "agent" => "chef", "customer" => "c-9" },
                                      updated_at: old, briefing: nil)
      }
      agents = [Insika::AgentProfile.build(id: "bia", model: "m", memory: true),
                profile("chef")]
      app, bus = build_app(agents: agents, sessions: sessions, proposal_store: seed_facts([]))
      client = login(app)
      csrf = csrf_from(client.get("/agents/bia").body)
      client.post("/agents/bia/distill", params: { "_csrf" => csrf })

      runs = bus.dispatched.select { |c| c.type == :run_distillation }
      expect(runs.map { |c| c.payload[:session_id] }).to eq(["s-bia"]) # chef's session never touched
    end

    it "POST harvest dispatches :run_harvest for the agent" do
      app, bus = build_app
      client = login(app)
      csrf = csrf_from(client.get("/agents/bia").body)
      client.post("/agents/bia/harvest", params: { "_csrf" => csrf })
      expect(bus.last(:run_harvest).payload).to include(agent: "bia")
    end

    it "POST refinement dispatches :run_refinement for the agent" do
      app, bus = build_app
      client = login(app)
      csrf = csrf_from(client.get("/agents/bia").body)
      client.post("/agents/bia/refinement", params: { "_csrf" => csrf })
      expect(bus.last(:run_refinement).payload).to include(agent: "bia")
    end
  end

  # --- Every shared screen is filterable by agent ----------------------------

  describe "the shared screens filter by agent" do
    def sess(id, agent)
      StoredSession.new(id: id,
                        messages: [{ "role" => "user", "content" => "hi #{id}" }],
                        vars: { "agent" => agent, "customer" => "c-#{id}" },
                        updated_at: "2026-08-15T10:00:00Z", briefing: nil)
    end

    it "chats?agent= narrows the list" do
      app, = build_app(sessions: { "s-1" => sess("s-1", "bia"), "s-2" => sess("s-2", "chef") })
      body = login(app).get("/chats?agent=bia").body
      expect(body).to include("s-1")
      expect(body).not_to include("s-2")
    end

    it "tasks?agent= narrows by the task's command payload" do
      tasks = { "t-1" => TaskDouble.new(id: "t-1", status: :completed,
                                        command: { "payload" => { "agent" => "bia" } },
                                        session_id: "s-1", executions: [], updated_at: "x"),
                "t-2" => TaskDouble.new(id: "t-2", status: :completed,
                                        command: { "payload" => { "agent" => "chef" } },
                                        session_id: "s-2", executions: [], updated_at: "x") }
      app, = build_app(tasks: tasks)
      body = login(app).get("/tasks?agent=bia").body
      expect(body).to include("t-1")
      expect(body).not_to include("t-2")
    end

    it "approvals?agent= narrows via the owning task" do
      tasks = { "t-1" => TaskDouble.new(id: "t-1", status: :running,
                                        command: { "payload" => { "agent" => "bia" } },
                                        session_id: "s-1", executions: [], updated_at: "x") }
      pendings = [StudioPendingRow.new(id: "p-1", task_id: "t-1", turn: 1, tool: "ship",
                                       args: {}, status: :pending, requested_at: "x")]
      app, = build_app(tasks: tasks, pendings: pendings)
      body = login(app).get("/approvals?agent=chef").body
      expect(body).not_to include("ship")
    end

    it "customers?agent= narrows to one tenant (the memory scope IS the agent)" do
      backend = Insika::Stores::Memory.new
      store = Insika::MemoryStore.new(store: backend)
      store.put_fact(tenant: "bia", customer: "c-1", key: "size", value: "M")
      store.put_fact(tenant: "chef", customer: "c-2", key: "size", value: "L")
      app, = build_app(agents: [profile("bia"), profile("chef")])
      # seed via the real store, then read through the app's own store
      app2 = Class.new(Studio::App)
      app2.configure(command_bus: BusDouble.new([]),
                     profile_source: ProfileSourceDouble.new([profile("bia"), profile("chef")]),
                     event_stream: nil, config: { admin_token: "s3cret" },
                     memory_store: store, session_secret: "x" * 64)
      body = login(app2).get("/customers?agent=bia").body
      expect(body).to include("c-1")
      expect(body).not_to include("c-2")
    end

    it "evals?agent= narrows the case list" do
      goldens = [
        { id: "g1", agent: "bia", turns: [{ "user" => "hi" }], expect: { "rubric" => "r" } },
        { id: "g2", agent: "chef", turns: [{ "user" => "hi" }], expect: { "rubric" => "r" } }
      ]
      app, = build_app(agents: [profile("bia"), profile("chef")], goldens: goldens)
      body = login(app).get("/evals?agent=bia").body
      expect(body).to include("g1")
      expect(body).not_to include("g2")
    end

    it "funnel?agent= shows only that agent's declaration" do
      app, = funnel_app(funnel_cells: [])
      body = login(app).get("/funnel?agent=funnel-store").body
      expect(body).to include("funnel-store")
      expect(body).not_to match(%r{<h2>chef})
    end

    it "facts?agent= matches by the origin session's agent stamp" do
      def clean_fact(id, key:, value:, session_ref:)
        { id: id, key: key, value: value, session_ref: session_ref, evidence: [1],
          status: "pending", current_value: nil, note: nil, confidence: nil, tenant: nil }
      end
      sessions = { "s-1" => sess("s-1", "bia"), "s-2" => sess("s-2", "chef") }
      rows = [clean_fact("p1", key: "size", value: "M", session_ref: "s-1"),
              clean_fact("p2", key: "color", value: "blue", session_ref: "s-2")]
      app, = build_app(agents: [profile("bia"), profile("chef")],
                       sessions: sessions, proposal_store: seed_facts(rows))
      body = login(app).get("/facts?agent=bia").body
      expect(body).to include("size")
      expect(body).not_to include("blue")
    end

    it "home?agent= narrows the counts and the recent list" do
      app, = build_app(sessions: { "s-1" => sess("s-1", "bia"), "s-2" => sess("s-2", "chef") })
      body = login(app).get("/home?agent=bia").body
      expect(body).to include("1</div>")
      expect(body).not_to include("s-2")
    end

    it "every filtered page renders the agent select" do
      app, = build_app
      # customers has its own drill (a real MemoryStore) — covered by its spec above
      %w[home chats tasks approvals evals funnel followups facts].each do |path|
        body = login(app).get("/#{path}").body
        expect(body).to include('name="agent"'), "#{path} lacks the agent filter"
      end
    end
  end

  it "saving a prompt dispatches write_agent_file (the Command syncs prompt_files)" do
    app, bus = build_app # bia has prompt_files: []
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    res = client.post("/agents/bia/prompts", params: {
                        "file" => "IDENTITY.md", "content" => "# Eu", "_csrf" => csrf
                      })
    expect(bus.last(:write_agent_file).payload).to include(agent_id: "bia", file: "IDENTITY.md")
    expect(bus.types).not_to include(:update_agent) # prompt_files sync belongs to the Command
    expect(res.headers["location"]).to eq("/studio/agents/bia/prompts/IDENTITY.md#prompts")
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
    fact = Insika::MemoryStore::Fact.new(key: "nome", value: "Ana", origin: "engine", created_at: "t", updated_at: "t", expires_at: nil)
    app, = build_app(memory: { "bia" => { facts: [fact], notes: [] } })
    body = login(app).get("/agents/bia").body
    expect(body).to include("nome")
    expect(body).to include("Ana")
  end

  # Skills (index + editor) — -----------------------------------

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

  # Eagerness is operational config, so it has to be editable without a script — and
  # it belongs on the SAME screen as the allowlist, because both are per-agent
  # decisions about one shared skill.
  it "the availability grid offers allowed AND always-on per agent" do
    app, = build_app(agents: [profile("bia", skills: ["pedido"], skills_eager: ["pedido"]),
                              profile("chef", skills: ["pedido"])])

    body = login(app).get("/skills/pedido").body

    expect(body).to include('name="agent_ids[]"', 'name="eager_ids[]"')
    grid = body[body.index("agent-grid")..]
    # bia has it always-on, chef only allowed: two checked allow boxes, ONE checked eager
    expect(grid.scan(/name="eager_ids\[\]" value="(\w+)" checked/).flatten).to eq(["bia"])
  end

  it "applying carries the eager list through" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/skills").body)

    client.post("/skills/pedido/agents",
                params: { "agent_ids" => %w[bia chef], "eager_ids" => %w[bia], "_csrf" => csrf })

    expect(bus.last(:set_skill_agents).payload[:eager_ids]).to eq(%w[bia])
  end

  # Specializing keeps a shared skill shared: the alternative was forking it under a
  # new name and editing the allowlist, which throws the sharing away.
  it "specialize seeds the agent's own version from the shared body and opens it" do
    app, bus = build_app(stored_skills: { "pedido" => "---\nname: pedido\n---\nshared body" })
    client = login(app)
    csrf = csrf_from(client.get("/skills/pedido").body)

    res = client.post("/skills/pedido/specialize", params: { "agent_id" => "chef", "_csrf" => csrf })

    cmd = bus.last(:write_skill)
    expect(cmd.payload).to include(name: "pedido", agent: "chef")
    expect(cmd.payload[:content]).to include("shared body") # seeded, not blank
    expect(res.headers["location"]).to eq("/studio/agents/chef/skills/pedido")
  end

  # A DISK skill has no store record, so the seed is RECONSTRUCTED — and it must carry
  # the whole frontmatter: an override that silently drops `triggers:` turns the
  # agent's deterministic activation off on day one.
  it "specialize preserves triggers and companions when seeding from a disk skill" do
    app, bus = build_app(skills: [SkillEntry.new(name: "pedido", description: "faz pedido", body: "corpo",
                                                 triggers: ["devolucao"], companions: ["query"])])
    client = login(app)
    csrf = csrf_from(client.get("/skills/pedido").body)

    client.post("/skills/pedido/specialize", params: { "agent_id" => "chef", "_csrf" => csrf })

    content = bus.last(:write_skill).payload[:content]
    expect(content).to include("triggers: devolucao", "companions: query", "corpo")
  end

  describe "an agent's own version of a skill" do
    let(:own) { { %w[chef pedido] => "---\nname: pedido\n---\nbody just for chef" } }

    # TWO path segments — which is why the store takes the agent as a second argument
    # and not as an "agent/name" key.
    it "opens at /agents/:id/skills/:name with that agent's body" do
      app, = build_app(stored_skills: { "pedido" => "---\nname: pedido\n---\nshared body" }, own_skills: own)

      body = login(app).get("/agents/chef/skills/pedido").body

      expect(body).to include("body just for chef")
      expect(body).not_to include("shared body")
      expect(body).to include("specialized for chef")
    end

    it "saving it writes into the agent scope, not the shared one" do
      app, bus = build_app(own_skills: own)
      client = login(app)
      csrf = csrf_from(client.get("/agents/chef/skills/pedido").body)

      client.post("/agents/chef/skills/pedido", params: { "content" => "---\nname: pedido\n---\nv2", "_csrf" => csrf })

      expect(bus.last(:write_skill).payload).to include(name: "pedido", agent: "chef")
    end

    it "stop specializing deletes only the override, and returns to the shared skill" do
      app, bus = build_app(own_skills: own)
      client = login(app)
      csrf = csrf_from(client.get("/agents/chef/skills/pedido").body)

      res = client.post("/agents/chef/skills/pedido/delete", params: { "_csrf" => csrf })

      expect(bus.last(:delete_skill).payload).to include(name: "pedido", agent: "chef")
      expect(res.headers["location"]).to eq("/studio/skills/pedido")
    end

    # Discoverability: an override that only exists in the store is an override nobody
    # finds. The shared skill's own grid links to it.
    it "the shared skill's grid links to an agent that has its own version" do
      app, = build_app(own_skills: own)

      body = login(app).get("/skills/pedido").body

      expect(body).to include("/studio/agents/chef/skills/pedido", "own version")
    end
  end

  # Tools (matriz) — --------------------------------------------

  it "lists the tools-by-agent matrix" do
    app, = build_app
    body = login(app).get("/tools").body
    expect(body).to include("menu")               # tool from the catalog
    expect(body).to include('name="all_tools"')
  end

  it "renders the matrix affordances: filter box, live counter, switch toggle" do
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

  # Data-driven tools (authoring) — ---------------------

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

  # The form renders neither halt_when nor group/tags, and the store REPLACES the
  # record: without carrying them through, editing the description alone would erase
  # the halt condition and the customer would start getting the duplicate message again.
  it "POST /tools/def/:name preserves the fields the form does not render" do
    tool = data_tool(name: "subscribe", group: "crm", tags: %w[crm retail],
                     halt_when: { json_path: "tool_result.status", equals: ["SUBSCRIBED"] })
    app, bus = build_app(data_tools: [tool])
    client = login(app)
    csrf = csrf_from(client.get("/tools/def/subscribe").body)

    client.post("/tools/def/subscribe", params: {
                  "name" => "subscribe", "description" => "só corrigi a descrição",
                  "method" => "POST", "url" => "https://app.test/subscribe", "_csrf" => csrf
                })

    p = bus.last(:write_data_tool).payload
    expect(p[:description]).to eq("só corrigi a descrição")
    expect(p["halt_when"]).to eq("json_path" => "tool_result.status", "equals" => ["SUBSCRIBED"])
    expect(p["group"]).to eq("crm")
    expect(p["tags"]).to eq(%w[crm retail])
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

  # History (read-only viewer) — --------------------------------

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

  it "session viewer shows the context breakdown by category" do
    sess = StoredSession.new(id: "sess-c", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    ctx = { "sess-c" => [{ task_id: "t1", turn: 1, at: "2026-08-10T00:00:00Z",
                           cap: 8_000, used: 6_120, evicted: ["session"],
                           categories: { "prompt" => { tokens: 4_100, fragments: 2, pinned: 4_100 },
                                         "session" => { tokens: 1_900, fragments: 1, pinned: 0 } },
                           tools: { count: 9, tokens: 1_200 } }] }
    app, = build_app(sessions: { "sess-c" => sess }, context_traces: ctx)
    body = login(app).get("/sessions/sess-c").body
    expect(body).to include("Context")
    expect(body).to include("6120 / 8000")              # the budget line
    expect(body).to include("prompt")                   # a category row
    expect(body).to include("4100 tokens · 2 fragment(s)") # tokens + fragment count
    expect(body).to include("evicted: session")         # the budget cut something
    expect(body).to include("9 tool schema(s)")         # the tools estimate
  end

  # RFC-0030 C9 — the per-turn cache line on the Context card: the provider-
  # reported hit % and the first category whose bytes diverged from the
  # previous turn (PII-free), plus the identity boundary marker per category.
  describe "session viewer cache line (RFC-0030)" do
    def cache_trace
      { "sess-cx" => [{ task_id: "t1", turn: 1, at: "2026-08-10T00:00:00Z",
                        cap: 8_000, used: 6_120, evicted: [],
                        categories: { "prompt" => { tokens: 4_100, fragments: 2, pinned: 4_100,
                                                    layer: "identity" },
                                      "session" => { tokens: 1_900, fragments: 1, pinned: 0,
                                                     layer: "volatile" } },
                        tools: { count: 9, tokens: 1_200 },
                        cache: { hit_pct: 83, cached_tokens: 21_845, prompt_tokens: 26_319,
                                 invalidation_reason: "memory" } }] }
    end

    it "shows the cached badge and the broke: line on the turn summary" do
      sess = StoredSession.new(id: "sess-cx", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
      app, = build_app(sessions: { "sess-cx" => sess }, context_traces: cache_trace)
      body = login(app).get("/sessions/sess-cx").body
      expect(body).to include("83% cached")
      expect(body).to include("broke: memory")
    end

    it "marks the identity boundary on the category rows" do
      sess = StoredSession.new(id: "sess-cx", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
      app, = build_app(sessions: { "sess-cx" => sess }, context_traces: cache_trace)
      body = login(app).get("/sessions/sess-cx").body
      expect(body).to include("4100 tokens · 2 fragment(s) · pinned · identity")
      expect(body).to include("1900 tokens · 1 fragment(s)")
      expect(body).not_to include("1900 tokens · 1 fragment(s) · identity")
    end

    it "an entry without cache fields (pre-RFC trace) renders neither the badge nor the broke line" do
      sess = StoredSession.new(id: "sess-cx", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
      trace = { "sess-cx" => [{ task_id: "t1", turn: 1, at: "2026-08-10T00:00:00Z",
                                cap: 8_000, used: 6_120, evicted: [],
                                categories: { "prompt" => { tokens: 4_100, fragments: 2, pinned: 4_100 } },
                                tools: { count: 9, tokens: 1_200 } }] }
      app, = build_app(sessions: { "sess-cx" => sess }, context_traces: trace)
      body = login(app).get("/sessions/sess-cx").body
      expect(body).not_to include("% cached")
      expect(body).not_to include("broke:")
    end
  end

  # Once bodies arrive by context instead of a load_skill call, this list is the
  # only after-the-fact answer to "which skills did the turn get?".
  it "session viewer names the skills injected into the turn" do
    sess = StoredSession.new(id: "sess-sk", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    ctx = { "sess-sk" => [{ task_id: "t1", turn: 1, at: "2026-08-10T00:00:00Z",
                            cap: 60_000, used: 20_000, evicted: [],
                            categories: {
                              "skilltrigger" => { tokens: 14_371, fragments: 1, pinned: 0,
                                                  labels: [{ "name" => "gift-concierge", "reason" => "trigger:presente" },
                                                           { "name" => "prisma-line-expert", "reason" => "eager" }] },
                              "prompt" => { tokens: 5_600, fragments: 1, pinned: 5_600 }
                            },
                            tools: { count: 17, tokens: 3_430 } }] }
    app, = build_app(sessions: { "sess-sk" => sess }, context_traces: ctx)

    body = login(app).get("/sessions/sess-sk").body

    expect(body).to include("skilltrigger")
    # the name AND the reason: a bare name does not say whether the operator triggered
    # it or the agent always carries it, which is the question the card exists for
    expect(body).to include("gift-concierge · trigger:presente, prisma-line-expert · eager")
    # the card is collapsed, so the count has to be readable WITHOUT expanding it
    expect(body).to include("skills 2")
  end

  # A context-injected skill is not a message, so the thread showed nothing — while a
  # model-loaded one shows up on its own (load_skill is a tool). Synthesized into the
  # transcript, placed by time so it lands at the top of its own turn.
  it "transcript shows a context-injected skill card, in turn order" do
    sess = StoredSession.new(
      id: "sess-inline", updated_at: "t",
      messages: [{ "role" => "user", "content" => "oi", "at" => "2026-08-12T10:00:05Z" },
                 { "role" => "assistant", "content" => "ola", "at" => "2026-08-12T10:00:05Z" },
                 { "role" => "user", "content" => "e agora", "at" => "2026-08-12T10:00:20Z" },
                 { "role" => "assistant", "content" => "pronto", "at" => "2026-08-12T10:00:20Z" }]
    )
    entry = lambda do |at, labels|
      { task_id: "t#{at}", turn: 1, at: at, cap: 60_000, used: 900, evicted: [],
        categories: { "skilltrigger" => { tokens: 500, fragments: 1, pinned: 0, labels: labels } },
        tools: { count: 0, tokens: 0 } }
    end
    ctx = { "sess-inline" => [
      entry.call("2026-08-12T10:00:01Z", [{ "name" => "gift-concierge", "reason" => "trigger:presente" }]),
      entry.call("2026-08-12T10:00:15Z", [{ "name" => "mapa", "reason" => "eager" },
                                          { "name" => "query", "reason" => "eager" }])
    ] }
    app, = build_app(sessions: { "sess-inline" => sess }, context_traces: ctx)

    body = login(app).get("/sessions/sess-inline").body
    thread = body[body.index('class="thread"')..]

    # the summary names the SHARED reason of the turn — one trigger, then two eager
    expect(thread).to include("skills · trigger (1)")
    expect(thread).to include("skills · eager (2)")
    # each card sits BEFORE the turn it belongs to
    expect(thread.index("skills · trigger (1)")).to be < thread.index("ola")
    expect(thread.index("skills · eager (2)")).to be < thread.index("pronto")
    expect(thread.index("ola")).to be < thread.index("skills · eager (2)")
  end

  it "a message without a timestamp flushes no inline card (older sessions degrade quietly)" do
    sess = StoredSession.new(id: "sess-nots", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "oi" }])
    ctx = { "sess-nots" => [{ task_id: "t1", turn: 1, at: "2026-08-12T10:00:01Z", cap: 60_000,
                              used: 900, evicted: [],
                              categories: { "skilltrigger" => { tokens: 500, fragments: 1,
                                                                pinned: 0, labels: ["mapa"] } },
                              tools: { count: 0, tokens: 0 } }] }
    app, = build_app(sessions: { "sess-nots" => sess }, context_traces: ctx)

    body = login(app).get("/sessions/sess-nots").body

    expect(body[body.index('class="thread"')..]).not_to include("skills · context")
    expect(body).to include("skills 1") # the Context card still reports it
  end

  it "no skills injected -> no skills badge (an empty one reads as zero, not as absent)" do
    sess = StoredSession.new(id: "sess-ns", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    ctx = { "sess-ns" => [{ task_id: "t1", turn: 1, at: "t", cap: 8_000, used: 900, evicted: [],
                            categories: { "prompt" => { tokens: 900, fragments: 1, pinned: 900 } },
                            tools: { count: 0, tokens: 0 } }] }
    app, = build_app(sessions: { "sess-ns" => sess }, context_traces: ctx)

    expect(login(app).get("/sessions/sess-ns").body).not_to include("skills ")
  end

  it "session viewer without a context trace omits the card (nil store = off)" do
    sess = StoredSession.new(id: "sess-nc", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-nc" => sess })
    body = login(app).get("/sessions/sess-nc").body
    expect(body).not_to include("tokens by category")
  end

  # RFC-0028 — the read-only briefing card shows PERSISTED state only (known
  # fields + next step). The missing list is model-facing and lives in the
  # context provider, not here (D6).
  it "session viewer renders the briefing card (known fields + next step)" do
    sess = StoredSession.new(
      id: "sess-bf", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }],
      briefing: { "fields" => { "size" => "M", "budget" => "400" },
                  "next_step" => "send the payment link tomorrow at 10" }
    )
    app, = build_app(sessions: { "sess-bf" => sess })
    body = login(app).get("/sessions/sess-bf").body
    expect(body).to include("Briefing")
    expect(body).to include("size")
    expect(body).to include("M")
    expect(body).to include("budget")
    expect(body).to include("400")
    expect(body).to include("next step")
    expect(body).to include("send the payment link tomorrow at 10")
  end

  it "session viewer renders the briefing card with a next step only" do
    sess = StoredSession.new(
      id: "sess-bs", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }],
      briefing: { "fields" => {}, "next_step" => "chamar de volta às 10" }
    )
    app, = build_app(sessions: { "sess-bs" => sess })
    body = login(app).get("/sessions/sess-bs").body
    expect(body).to include("Briefing")
    expect(body).to include("chamar de volta às 10")
  end

  it "an old record without a briefing renders no briefing card (D1 default, no nil leak)" do
    sess = StoredSession.new(id: "sess-bn", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-bn" => sess })
    body = login(app).get("/sessions/sess-bn").body
    expect(body).not_to include("this conversation's working state")
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

  it "session viewer renders structured content as pretty JSON, not Ruby #inspect" do
    sess = StoredSession.new(id: "sess-j", updated_at: "t",
                             messages: [{ "role" => "assistant", "content" => { "text" => "hi" } }])
    app, = build_app(sessions: { "sess-j" => sess })
    body = login(app).get("/sessions/sess-j").body
    expect(body).to include("&quot;text&quot;") # JSON quotes, escaped once
    expect(body).not_to include("=&gt;")         # NOT a Ruby hashrocket (#inspect)
  end

  it "session viewer renders a tool message as a collapsible card" do
    sess = StoredSession.new(id: "sess-tool", updated_at: "t",
                             messages: [{ "role" => "tool", "content" => "resultado-da-tool" }])
    app, = build_app(sessions: { "sess-tool" => sess })
    body = login(app).get("/sessions/sess-tool").body
    expect(body).to include("resultado-da-tool")
    expect(body).to include('class="toolcard result"')
  end

  it "session viewer renders an assistant's tool_calls as cards (R1)" do
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

  # Settings --------------------------------------------------

  it "the app-bar has the links (mcp/system/chats/settings)" do
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
    # the compaction form is gone while nothing consumes the key.
    expect(res.body).not_to include("compaction")
    csrf = csrf_from(res.body)
    client.post("/settings", params: {
                  "streaming" => "1", "turn_timeout" => "300", "_csrf" => csrf
                })
    patch = bus.last(:update_settings).payload[:patch]
    expect(patch["streaming"]).to be(true)
    expect(patch["turn_timeout"]).to eq(300)
    expect(patch).not_to have_key("compaction")
  end

  it "settings without the streaming checkbox sends streaming=false" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings", params: { "turn_timeout" => "90", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["streaming"]).to be(false)
  end

  describe "Customers drill (RFC-0031 C8)" do
    # The drill reads the REAL MemoryStore (customer_cells/facts — the doubles
    # other pages use don't model cells). The bus executes the REAL commands
    # (export must produce a body; edit/forget must land in the store) and
    # records the dispatches for assertion.
    def build_customers_app(store, audit: nil, agents: [profile("bia")])
      real = Insika::CommandBus.new
      es = Insika::EventStream.new
      sessions = Insika::SessionStore.new(store: backend)
      real.register(:export_customer_memory,
                    Insika::Commands::ExportCustomerMemory.new(memory_store: store, event_stream: es))
      real.register(:memory_put_fact,
                    Insika::Commands::MemoryPutFact.new(memory_store: store, event_stream: es, audit_store: audit))
      real.register(:memory_forget_fact,
                    Insika::Commands::MemoryForgetFact.new(memory_store: store, event_stream: es, audit_store: audit))
      real.register(:forget_customer,
                    Insika::Commands::ForgetCustomer.new(memory_store: store, session_store: sessions,
                                                         event_stream: es))
      bus = StudioRecordingBus.new(real)
      app = Class.new(Studio::App)
      app.configure(
        command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
        event_stream: nil, config: { admin_token: "s3cret" },
        memory_store: store, memory_audit_store: audit, session_secret: "x" * 64
      )
      [app, bus]
    end

    let(:backend) { Insika::Stores::Memory.new }
    let(:store) { Insika::MemoryStore.new(store: backend) }
    let(:audit) { Insika::MemoryAuditStore.new(store: backend) }
    let(:app) { build_customers_app(store, audit: audit) }
    let(:path) { "/customers/#{Rack::Utils.escape('memory:acme:c-1')}" }

    it "the index lists customer cells and hides _default, bare agent cells and SESSION cells" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      store.put_fact(tenant: nil, key: "k", value: "v") # _default — the shared cell
      store.put_fact(tenant: nil, customer: "bia", key: "k", value: "v") # an agent id (reserved)
      store.put_fact(tenant: nil, customer: "solo", key: "k", value: "v") # bare customer
      store.put_fact(tenant: "chat:34403117-4b5d-48ab-a1b2-1234567890ab", key: "k", value: "v") # a session cell

      body = login(app.first).get("/customers").body

      expect(body).to include("c-1")
      expect(body).to include("solo")
      expect(body).to include("Shared (no tenant)") # the bare cells group
      expect(body).not_to include("_default")
      expect(body).not_to match(%r{<h2>bia</h2>}) # the reserved agent cell is not a section
      expect(body).not_to include("34403117") # a conversation is never a customer
    end

    it "the detail renders facts with origin/expiry, notes and the audit lines" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M",
                     expires_at: "2099-01-01T00:00:00Z")
      store.add_note(tenant: "acme", customer: "c-1", text: "prefere email")
      audit.record(cell: "memory:acme:c-1", action: "put", actor: "studio", key: "size",
                   tenant: "acme", customer: "c-1", new_hash: "a1b2")

      body = login(app.first).get(path).body

      expect(body).to include("size")
      expect(body).to include(">M<")
      expect(body).to include("engine") # origin
      expect(body).to include("expires") # expiry column
      expect(body).to include("prefere email") # note
      expect(body).to include("a1b2") # audit digest
    end

    it "editing a fact POSTs :memory_put_fact with the parsed pair and operator: studio" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      client = login(app.first)
      csrf = csrf_from(client.get(path).body)

      client.post("#{path}/fact", params: { "key" => "size", "value" => "L", "_csrf" => csrf })

      cmd = app.last.last(:memory_put_fact)
      expect(cmd.payload).to include(tenant: "acme", customer: "c-1",
                                     key: "size", value: "L", operator: "studio")
    end

    it "forget-fact POSTs :memory_forget_fact with the parsed pair" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      client = login(app.first)
      csrf = csrf_from(client.get(path).body)

      client.post("#{path}/forget-fact", params: { "key" => "size", "_csrf" => csrf })

      expect(app.last.last(:memory_forget_fact).payload)
        .to include(tenant: "acme", customer: "c-1", key: "size", operator: "studio")
    end

    it "export POST returns application/json with the attachment header and the facts in the body" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      client = login(app.first)
      csrf = csrf_from(client.get(path).body)

      res = client.post("#{path}/export", params: { "_csrf" => csrf })

      expect(res.status).to eq(200)
      expect(res.headers["content-type"]).to include("application/json")
      expect(res.headers["content-disposition"]).to include("attachment")
      expect(res.headers["content-disposition"]).to include("memory-acme-c-1.json")
      body = JSON.parse(res.body)
      expect(body["facts"].map { |f| f["key"] }).to eq(["size"])
      expect(body["counts"]).to eq({ "facts" => 1, "notes" => 0 })
      expect(app.last.last(:export_customer_memory).payload).to include(tenant: "acme", customer: "c-1")
    end

    it "export on a customer-less cell (memory:_default, reachable by URL) redirects with a red flash, never a 500" do
      client = login(app.first)
      csrf = csrf_from(client.get("/customers/memory%3A_default").body)

      res = client.post("/customers/memory%3A_default/export", params: { "_csrf" => csrf })

      expect(res.status).to eq(302)
      expect(res.headers["location"]).to include("/customers/memory:_default")
    end

    it "forget POST dispatches :forget_customer and redirects to the index" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      client = login(app.first)
      csrf = csrf_from(client.get(path).body)

      res = client.post("#{path}/forget", params: { "_csrf" => csrf })

      expect(res.status).to eq(302)
      expect(res.headers["location"]).to include("/customers")
      expect(app.last.last(:forget_customer).payload).to include(tenant: "acme", customer: "c-1")
    end

    it "without memory_store both pages render empty states and nothing raises" do
      app, bus = build_customers_app(nil)
      client = login(app)
      expect(client.get("/customers").status).to eq(200)
      expect(client.get("/customers").body).to include("No customers with memory yet")
      detail = client.get("/customers/#{Rack::Utils.escape('memory:acme:c-1')}")
      expect(detail.status).to eq(200)
      expect(detail.body).to include("No facts.")
    end
  end

  it "the memory TTL field lands a number in the settings record; blank clears it (RFC-0031 C5)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings", params: { "memory_ttl_days" => "45", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["memory_ttl_days"]).to eq(45)

    client.post("/settings", params: { "memory_ttl_days" => "", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["memory_ttl_days"]).to be_nil
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

  it "the edge-limits form dispatches update_settings with the edge layer only" do
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

  # MCP -------------------------------------------------------

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

  # System-files ----------------------------------------------

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

  # Chats -----------------------------------------------------

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

  # Polish & parity ---------------------------------

  it "the app-bar has a health chip and theme switch; the html loads the theme (auto default)" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('data-theme="auto"')
    expect(body).to include('data-controller="theme"')
    expect(body).to include("runtime online")
  end

  it "stamps each avatar with a deterministic hue class (the id's fingerprint)" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include(%(class="avatar avatar-h#{"bia".bytes.sum % 10}"))
    expect(body).to include(%(class="avatar avatar-h#{"chef".bytes.sum % 10}"))
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

  it "serves the favicon svg and links it from the layout (no /favicon.ico 401)" do
    app, = build_app
    res = Client.new(app).get("/assets/dist/favicon.svg")
    expect(res.status).to eq(200)
    expect(res.headers["content-type"]).to include("image/svg+xml")
    # The link is in the layout, so the unauthenticated login page has it too:
    # the browser requests THIS instead of the auth-protected root /favicon.ico.
    body = Client.new(app).get("/login").body
    expect(body).to match(%r{<link rel="icon" type="image/svg\+xml" href="/studio/assets/dist/favicon\.svg\?v=\d+">})
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
    app, = build_app(agents: [profile("bia", prompt_files: %w[SOUL.md])],
                     agent_files: { ["bia", "SOUL.md"] => "x" },
                     system_files: { "H.md" => "x" })
    client = login(app)
    expect(client.get("/agents/bia/prompts/SOUL.md").body).to include('data-controller="dirty-guard"')
    expect(client.get("/system-files").body).to include('data-controller="dirty-guard"')
    expect(client.get("/skills/new").body).to include('data-controller="dirty-guard"')
  end

  # UI robustness — (loading states) + (confirm + copy) -----------

  it "destructive forms carry a data-turbo-confirm prompt" do
    fact = Insika::MemoryStore::Fact.new(key: "nome", value: "Ana", origin: "engine", created_at: "t", updated_at: "t", expires_at: nil)
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
    detail = client.get("/agents/bia/prompts/SOUL.md").body
    expect(detail).to include("/prompts/delete", "data-turbo-confirm=")
    expect(client.get("/agents/bia").body).to include('/memory/forget" data-turbo-confirm=')
  end

  it "action buttons declare a data-turbo-submits-with loading label" do
    app, = build_app
    client = login(app)
    expect(client.get("/playground?agent=chef").body).to include('data-turbo-submits-with="Sending…"')
    expect(client.get("/agents/bia").body).to include("data-turbo-submits-with=")
  end

  it "the session id and tool-trace payloads load the clipboard island with a copy button" do
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

  it "the bundle registers the clipboard controller" do
    app, = build_app
    js = Client.new(app).get("/assets/dist/application.js").body
    expect(js).to include("clipboard")
  end

  # --- Agent creation (parity: "each one creates its own agent") -----------------

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
    expect(body).to include("Create your first agent")
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

  # Tasks & Approvals ------------------------------------------

  def task(id: "t1", status: :running, session_id: "s1", executions: [], timing: nil)
    TaskDouble.new(id: id, status: status, command: { "type" => "send_message" },
                   session_id: session_id, executions: executions, updated_at: "2026-07-21T00:00:00Z",
                   timing: timing)
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

  # RFC-0027 C5: the task page IS the ledger — first_balloon_ms shows there when a
  # channel turn recorded it, and a task without timing still renders.
  it "renders first_balloon_ms on the task page when present" do
    app, = build_app(tasks: { "t1" => task(timing: { "first_balloon_ms" => 812.5 }) })
    res = login(app).get("/tasks/t1")
    expect(res.body).to include("first_balloon_ms")
    expect(res.body).to include("812.5")
  end

  it "renders a task page without crashing when timing is nil (pre-RFC tasks)" do
    app, = build_app(tasks: { "t1" => task })
    expect(login(app).get("/tasks/t1").status).to eq(200)
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

# Evals: cases authored without a checkout -------------
# The rubric is the part of an eval a domain owner can write, so it has to be
# editable where they already are. Writes go through :write_golden like everything
# else — the Studio never touches a store directly.

def a_golden(id: "loja-cupom", agent: "loja")
  { "id" => id, "agent" => agent, "turns" => [{ "user" => "tem cupom?" }],
    "expect" => { "tools_called" => ["search_voucher"], "rubric" => "Consults the coupon by tool." } }
end

it "lists the stored cases grouped by agent (GET /evals)" do
  app, = build_app(goldens: [a_golden, a_golden(id: "outra-x", agent: "outra")])
  res = login(app).get("/evals")

  expect(res.status).to eq(200)
  expect(res.body).to include("loja-cupom", "outra-x", "2 case(s)")
end

it "opens a case as the same YAML the corpus files hold" do
  app, = build_app(goldens: [a_golden])
  body = login(app).get("/evals?id=loja-cupom").body

  expect(body).to include("id: loja-cupom")
  expect(body).to include("search_voucher")
  expect(body).to include("Consults the coupon by tool.")
end

it "offers a template when nothing is selected (an empty store is not a dead end)" do
  app, = build_app
  body = login(app).get("/evals").body
  expect(body).to include("No case yet", "insika evals:import", "min_score")
end

it "POST /evals dispatches :write_golden with the parsed case" do
  app, bus = build_app
  client = login(app)
  csrf = csrf_from(client.get("/evals").body)
  yaml = "id: novo\nagent: loja\nturns:\n  - user: oi\nexpect:\n  rubric: seja gentil\n"

  res = client.post("/evals", params: { "yaml" => yaml, "id" => "novo", "_csrf" => csrf })

  expect(res.status).to eq(302)
  expect(bus.last(:write_golden).payload[:case])
    .to eq({ "id" => "novo", "agent" => "loja", "turns" => [{ "user" => "oi" }],
             "expect" => { "rubric" => "seja gentil" } })
end

it "malformed YAML is a red flash, never a dispatch" do
  app, bus = build_app
  client = login(app)
  csrf = csrf_from(client.get("/evals").body)

  client.post("/evals", params: { "yaml" => "id: [unclosed", "_csrf" => csrf })

  expect(bus.types).not_to include(:write_golden)
  expect(client.get("/evals").body).to include("invalid YAML")
end

it "YAML that is not a mapping is refused with a message that says what is expected" do
  app, bus = build_app
  client = login(app)
  csrf = csrf_from(client.get("/evals").body)

  client.post("/evals", params: { "yaml" => "- just\n- a list\n", "_csrf" => csrf })

  expect(bus.types).not_to include(:write_golden)
  expect(client.get("/evals").body).to include("must be a YAML mapping")
end

it "flags stored cases that no longer validate — a run would skip them silently" do
  app, = build_app
  # Straight into the ConfigStore: the store's own write validates, so the only way to
  # hold a broken case is to have broken it underneath.
  app.insika[:golden_store].instance_variable_get(:@cs).put("goldens", "bad", { "case" => { "id" => "bad" } })

  expect(login(app).get("/evals").body).to include("no longer validate", "bad")
end

it "POST /evals/:id/delete dispatches :delete_golden" do
  app, bus = build_app(goldens: [a_golden])
  client = login(app)
  csrf = csrf_from(client.get("/evals?id=loja-cupom").body)

  res = client.post("/evals/loja-cupom/delete", params: { "_csrf" => csrf })

  expect(res.status).to eq(302)
  expect(bus.last(:delete_golden).payload).to eq(id: "loja-cupom")
end

it "the judges panel round-trips through Settings › Evals" do
  app, bus = build_app
  client = login(app)
  csrf = csrf_from(client.get("/settings?s=evals").body)

  client.post("/settings/evals", params: { "judges" => "deepseek/deepseek-chat\ngpt-5-mini\n\n",
                                          "aggregate" => "min", "min_agreement" => "1.0",
                                          "quorum" => "2", "tolerance" => "0.1", "_csrf" => csrf })

  patch = bus.last(:update_settings).payload[:patch]["evals"]
  expect(patch["judges"]).to eq([{ "provider" => "deepseek", "model" => "deepseek-chat" },
                                 { "model" => "gpt-5-mini" }])
  expect(patch.values_at("aggregate", "min_agreement", "quorum", "tolerance"))
    .to eq(["min", 1.0, 2, 0.1])
end

it "a non-numeric min_agreement is refused instead of quietly becoming 'off'" do
  app, bus = build_app
  client = login(app)
  csrf = csrf_from(client.get("/settings?s=evals").body)

  client.post("/settings/evals", params: { "min_agreement" => "half", "_csrf" => csrf })

  expect(bus.types).not_to include(:update_settings)
  expect(client.get("/settings?s=evals").body).to include("min_agreement must be a number")
end

  # Refinement ---------------------------------------
  # Read-only page + one button. There is no scheduler in the engine, so the button
  # (and the CLI) are how a run starts.

  it "shows the refinement empty-state before an agent has ever been run" do
    app, = build_app
    res = login(app).get("/refinement")
    expect(res.status).to eq(200)
    expect(res.body).to include("No run yet")
  end

  it "renders the latest report: kind, count, title and a link to the session" do
    finding = { "kind" => "tool_error", "key" => "tool_error:shipping_quote:cep is required",
                "title" => "shipping_quote failed: cep is required", "count" => 4,
                "severity" => 3, "sessions" => %w[sess-abc123456789], "detail" => nil }
    app, = build_app(refinement_runs: [{ agent: "bia", findings: [finding] }])

    res = login(app).get("/refinement?agent=bia")

    expect(res.body).to include("tool_error")
    expect(res.body).to include("shipping_quote failed: cep is required")
    expect(res.body).to include("×4")
    expect(res.body).to include("/studio/sessions/sess-abc123456789")
  end

  it "says so when the window was clean (a run with no findings)" do
    app, = build_app(refinement_runs: [{ agent: "bia", findings: [] }])
    expect(login(app).get("/refinement?agent=bia").body).to include("Nothing found in this window")
  end

  # Refinement: the review IS the product -------

  # Seeds a run parked on a human, the state the proposal card renders.
  def awaiting_run(store, agent: "bia")
    row = store.create(agent_id: agent, at: "2026-08-05T10:00:00Z")
    store.complete(row.id, findings: [{ "kind" => "tool_error", "count" => 4, "title" => "t" }])
    store.gating(row.id, candidate: {
                   "id" => "cand-1", "proposer" => "deepseek/deepseek-v4-flash",
                   "rationale" => "TOOLS.md never says the CEP is required.",
                   "edits" => [{ "file" => "TOOLS.md", "op" => "replace", "anchor" => "## shipping_quote",
                                 "before" => "Use shipping_quote to quote freight.",
                                 "after" => "Use shipping_quote. Ask for the CEP first.",
                                 "addresses" => ["tool_error:shipping_quote"] }],
                   "dropped" => []
                 })
    store.gated(row.id, report: { "candidate_id" => "cand-1", "passed" => true, "reason" => nil,
                                  "cases" => 7, "passed_cases" => 5, "baseline_cases" => 7,
                                  "regressions" => [], "report" => {} })
  end

  it "renders a gated proposal: the diff, what it addresses, and how it scored" do
    app, = build_app
    awaiting_run(app.insika[:refinement_store])

    body = login(app).get("/refinement?agent=bia").body

    expect(body).to include("Ask for the CEP first.")            # the + side
    expect(body).to include("Use shipping_quote to quote freight.") # the - side
    expect(body).to include("5/7 case(s)")
    expect(body).to include("deepseek/deepseek-v4-flash")
    expect(body).to include("tool_error:shipping_quote")
    expect(body).to include("Approve &amp; apply")
  end

  it "shows no proposal card when nothing is awaiting a human" do
    app, = build_app(refinement_runs: [{ agent: "bia", findings: [{ "kind" => "x", "count" => 1, "title" => "t" }] }])
    expect(login(app).get("/refinement?agent=bia").body).not_to include("awaiting your approval")
  end

  it "POST /refinement/resolve dispatches :resolve_refinement with the operator's answer" do
    app, bus = build_app
    run = awaiting_run(app.insika[:refinement_store])
    client = login(app)
    csrf = csrf_from(client.get("/refinement?agent=bia").body)

    res = client.post("/refinement/resolve",
                      params: { "agent" => "bia", "run_id" => run.id, "decision" => "approved",
                                "note" => "makes sense", "_csrf" => csrf })

    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/refinement?agent=bia")
    expect(bus.last(:resolve_refinement).payload)
      .to eq(run_id: run.id, decision: "approved", operator: "studio", note: "makes sense")
  end

  it "POST /refinement/resolve carries a rejection through the same route" do
    app, bus = build_app
    run = awaiting_run(app.insika[:refinement_store])
    client = login(app)
    csrf = csrf_from(client.get("/refinement?agent=bia").body)

    client.post("/refinement/resolve",
                params: { "agent" => "bia", "run_id" => run.id, "decision" => "rejected", "_csrf" => csrf })

    expect(bus.last(:resolve_refinement).payload[:decision]).to eq("rejected")
  end

  # Refinement: the model writes the candidate --------------------

  it "offers Propose a fix on a finished report that found something" do
    app, = build_app(refinement_runs: [{ agent: "bia", findings: [{ "kind" => "tool_error", "count" => 4,
                                                                    "title" => "t" }] }])
    body = login(app).get("/refinement?agent=bia").body

    expect(body).to include("Propose a fix")
    expect(body).to include("/studio/refinement/propose")
  end

  it "does not offer a proposal on a clean window or while one awaits an answer" do
    app, = build_app(refinement_runs: [{ agent: "bia", findings: [] }])
    expect(login(app).get("/refinement?agent=bia").body).not_to include("Propose a fix")

    app2, = build_app
    awaiting_run(app2.insika[:refinement_store])
    expect(login(app2).get("/refinement?agent=bia").body).not_to include("Propose a fix")
  end

  it "POST /refinement/propose dispatches :gate_refinement with propose: true" do
    app, bus = build_app(refinement_runs: [{ agent: "bia", findings: [{ "kind" => "tool_error", "count" => 4,
                                                                        "title" => "t" }] }])
    client = login(app)
    body = client.get("/refinement?agent=bia").body
    run_id = app.insika[:refinement_store].for_agent("bia").first.id

    res = client.post("/refinement/propose",
                      params: { "agent" => "bia", "run_id" => run_id, "_csrf" => csrf_from(body) })

    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/refinement?agent=bia")
    expect(bus.last(:gate_refinement).payload).to eq(run_id: run_id, propose: true)
  end

  # A gate that refused is the most useful thing on the page: without it, pressing
  # the button and getting nothing back reads as a bug.
  it "shows why the gate refused the last proposal" do
    app, = build_app
    store = app.insika[:refinement_store]
    row = store.create(agent_id: "bia", at: "2026-08-05T10:00:00Z")
    store.complete(row.id, findings: [{ "kind" => "tool_error", "count" => 4, "title" => "t" }])
    store.gating(row.id, candidate: { "id" => "c1", "edits" => [], "dropped" => [] })
    store.gated(row.id, report: { "candidate_id" => "c1", "passed" => false,
                                  "reason" => "1 regression(s): quotes (pass→fail)",
                                  "cases" => 7, "passed_cases" => 4, "baseline_cases" => 7,
                                  "regressions" => [{ "id" => "quotes" }], "report" => {} })

    body = login(app).get("/refinement?agent=bia").body
    expect(body).to include("gate refused")
    expect(body).to include("1 regression(s): quotes")
  end

  # Refinement: the panel and the unattended write ---

  # A run whose panel had three members: the winner, a loser and one the budget
  # never got to.
  def panel_run(store, agent: "bia")
    row = store.create(agent_id: agent, at: "2026-08-07T10:00:00Z")
    store.complete(row.id, findings: [{ "kind" => "tool_error", "count" => 4, "title" => "t" }])
    winner = { "id" => "c1", "proposer" => "deepseek-chat", "rationale" => "the CEP",
               "edits" => [{ "file" => "TOOLS.md", "op" => "replace",
                             "before" => "Use shipping_quote.", "after" => "Ask for the CEP first.",
                             "addresses" => [] }], "dropped" => [] }
    loser = { "id" => "c2", "proposer" => "gpt-5-mini", "edits" => [], "dropped" => [] }
    unfunded = { "id" => "c3", "proposer" => "claude-haiku", "edits" => [], "dropped" => [] }
    store.gating(row.id, candidates: [winner, loser, unfunded])
    store.gated(row.id,
                report: verdict("c1", passed: true, passed_cases: 6),
                panel: [{ "candidate" => winner, "proposers" => ["deepseek-chat"],
                          "gate" => verdict("c1", passed: true, passed_cases: 6) },
                        { "candidate" => loser, "proposers" => ["gpt-5-mini"],
                          "gate" => verdict("c2", passed: false, passed_cases: 3) },
                        { "candidate" => unfunded, "proposers" => ["claude-haiku"],
                          "gate" => verdict("c3", passed: false, passed_cases: 0,
                                                  reason: "not gated — the run's token budget (900) was spent",
                                                  cases: 0) }],
                cost: { "tokens" => 900, "spent" => 912, "unmetered" => 1 })
  end

  def verdict(id, passed:, passed_cases:, reason: nil, cases: 7)
    { "candidate_id" => id, "passed" => passed,
      "reason" => reason || (passed ? nil : "1 regression(s): quotes (pass→fail)"),
      "cases" => cases, "passed_cases" => passed_cases, "baseline_cases" => 7,
      "regressions" => [], "report" => {}, "tokens" => 300 }
  end

  it "shows the winner as best of the panel, with the run's cost and the losers" do
    app, = build_app
    panel_run(app.insika[:refinement_store])

    body = login(app).get("/refinement?agent=bia").body

    expect(body).to include("best of 3 candidate(s)")
    expect(body).to include("912 tokens")
    expect(body).to include("Also proposed")
    expect(body).to include("gpt-5-mini")
    expect(body).to include("claude-haiku")
    expect(body).to include("token budget (900) was spent")
  end

  # an operator who wakes up to a changed prompt gets what changed, why, and
  # where to undo it — the write versioned, so History IS the undo.
  it "shows what auto_apply changed, and where to undo it" do
    app, = build_app
    store = app.insika[:refinement_store]
    run = panel_run(store)
    store.resolve(run.id, decision: :applied, operator: "auto_apply",
                          note: "auto_apply: gate passed 6/7 with no regression")

    body = login(app).get("/refinement?agent=bia").body

    expect(body).to include("auto-applied")
    expect(body).to include("auto_apply: gate passed 6/7")
    expect(body).to include("Ask for the CEP first.")
    expect(body).to include("Undo it from the file's History")
  end

  it "POST /refinement dispatches :run_refinement for the chosen agent" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/refinement").body)

    res = client.post("/refinement", params: { "agent" => "chef", "_csrf" => csrf })

    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/refinement?agent=chef")
    expect(bus.last(:run_refinement).payload).to eq(agent: "chef", full: false)
  end

  it "the full-window checkbox reaches the command as a boolean" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/refinement").body)

    client.post("/refinement", params: { "agent" => "bia", "full" => "1", "_csrf" => csrf })

    expect(bus.last(:run_refinement).payload[:full]).to be(true)
  end

  it "POST /refinement without the CSRF token never dispatches" do
    app, bus = build_app
    client = login(app)
    client.get("/refinement")
    expect(client.post("/refinement", params: { "agent" => "bia" }).status).to eq(403)
    expect(bus.types).not_to include(:run_refinement)
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

  # Funnel (RFC-0032 C9) -------------------------------------------

  FUNNEL_DECL = { "stages" => %w[greeted qualified cart paid],
                  "advance_on" => { "qualified" => "qualified", "pix_paid" => "paid" },
                  "primary" => "paid", "attribution_window" => "72h" }.freeze

  # Cells are keyed by UTC date while the page windows with Date.today — seed
  # RELATIVE to today so these specs do not expire (fixed dates did, and the
  # page has no injectable clock by design).
  def funnel_cell(days_ago, agent: "funnel-store", tenant: nil, counts:)
    t = Date.today - days_ago
    { tenant: tenant, agent: agent, at: Time.utc(t.year, t.month, t.day, 10),
      counts: counts }
  end

  def funnel_app(funnel_cells: nil, budget: nil, outcomes: [], sessions: {})
    agents = [profile("funnel-store", funnel: FUNNEL_DECL), profile("chef")]
    build_app(agents: agents, funnel_cells: funnel_cells, budget: budget,
              outcomes: outcomes, sessions: sessions)
  end

  it "the funnel index lists only agents with a valid declaration, with counts over the period" do
    cells = [
      funnel_cell(3, counts: { "greeted" => 10, "qualified" => 5, "paid" => 2 }),
      funnel_cell(1, counts: { "greeted" => 5, "qualified" => 3, "paid" => 1 })
    ]
    app, = funnel_app(funnel_cells: cells)
    body = login(app).get("/funnel").body

    expect(body).to include("funnel-store")
    expect(body).not_to match(%r{<h2>chef}) # no declaration -> no block (the filter select lists every agent)
    # the stage rows carry "stage · count" — structured, not SVG noise
    expect(body).to include("greeted · 15")
    expect(body).to include("qualified · 8")
    expect(body).to include("paid · 3")
    expect(body).to include("conversion 0.2000") # 3 / 15
  end

  it "the period param switches the window" do
    cells = [
      funnel_cell(40, counts: { "greeted" => 99, "paid" => 1 }),
      funnel_cell(1, counts: { "greeted" => 5, "paid" => 1 })
    ]
    app, = funnel_app(funnel_cells: cells)
    body = login(app).get("/funnel?period=7").body
    expect(body).to include("greeted · 5")
    expect(body).not_to include("greeted · 99") # outside the window
    expect(body).to include("paid · 1")
  end

  it "a malformed period param falls back to 30 days" do
    cells = [funnel_cell(1, counts: { "greeted" => 5 })]
    app, = funnel_app(funnel_cells: cells)
    body = login(app).get("/funnel?period=abc").body
    expect(body).to include("greeted · 5")
  end

  it "the empty state renders without a store collaborator" do
    agents = [profile("chef")]
    app, = build_app(agents: agents)
    body = login(app).get("/funnel").body
    expect(body).to include("No outcome funnel declared")
  end

  it "the freeze POST dispatches :freeze_funnel_baseline with from/to and redirects" do
    app, bus = funnel_app(funnel_cells: [funnel_cell(1, counts: { "greeted" => 1 })])
    client = login(app)
    csrf = csrf_from(client.get("/funnel").body)
    res = client.post("/funnel/funnel-store/freeze",
                      params: { "from" => "2026-07-01", "to" => "2026-08-10", "_csrf" => csrf })
    expect(res.headers["location"]).to eq("/studio/funnel")
    cmd = bus.last(:freeze_funnel_baseline)
    expect(cmd.payload).to include(agent: "funnel-store", from: "2026-07-01",
                                   to: "2026-08-10", operator: "studio")
  end

  # blocker: the card's hidden tenant field must REACH the command — without
  # it, a multi-tenant freeze writes the "platform" baseline instead of the
  # store's, and the Studio reads the wrong cells for the sums.
  it "the freeze POST carries the card's tenant into the payload" do
    app, bus = funnel_app(funnel_cells: [funnel_cell(1, tenant: "acme", counts: { "greeted" => 1 })])
    client = login(app)
    csrf = csrf_from(client.get("/funnel").body)
    client.post("/funnel/funnel-store/freeze",
                params: { "tenant" => "acme", "_csrf" => csrf })
    expect(bus.last(:freeze_funnel_baseline).payload).to include(tenant: "acme")
  end

  it "a multi-tenant freeze lands on THAT tenant's baseline (real command, end to end)" do
    funnel_store = Insika::FunnelStore.new(store: Insika::Stores::Memory.new)
    30.times do |i|
      funnel_store.add(tenant: "acme", agent: "funnel-store",
                       at: Time.utc(2026, 7, 1 + i, 10), counts: { "greeted" => 1, "paid" => 1 })
    end
    bus = Insika::CommandBus.new
    bus.register(:freeze_funnel_baseline,
                 Insika::Commands::FreezeFunnelBaseline.new(
                   funnel_store: funnel_store,
                   profiles: ProfileSourceDouble.new([profile("funnel-store", funnel: FUNNEL_DECL)]),
                   event_stream: Insika::EventStream.new
                 ))
    recording = StudioRecordingBus.new(bus)
    app = Class.new(Studio::App)
    app.configure(command_bus: recording,
                  profile_source: ProfileSourceDouble.new([profile("funnel-store", funnel: FUNNEL_DECL)]),
                  event_stream: nil, config: { admin_token: "s3cret" },
                  funnel_store: funnel_store, session_secret: "x" * 64)
    client = login(app)
    csrf = csrf_from(client.get("/funnel").body)
    res = client.post("/funnel/funnel-store/freeze",
                      params: { "tenant" => "acme", "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(funnel_store.baseline(tenant: "acme", agent: "funnel-store")).not_to be_nil
    expect(funnel_store.baseline(tenant: "platform", agent: "funnel-store")).to be_nil
    expect(recording.last(:freeze_funnel_baseline).payload[:tenant]).to eq("acme")
  end

  it "a ValidationError (short span) renders the flash, not a crash" do
    bus = Class.new(BusDouble) do
      def dispatch(command)
        raise Insika::ValidationError, "baseline span must cover at least 28 days" if command.type == :freeze_funnel_baseline

        super
      end
    end.new([])
    agents = [profile("funnel-store", funnel: FUNNEL_DECL)]
    app = Class.new(Studio::App)
    app.configure(command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
                  event_stream: nil, config: { admin_token: "s3cret" },
                  funnel_store: Insika::FunnelStore.new(store: Insika::Stores::Memory.new),
                  session_secret: "x" * 64)
    client = login(app)
    csrf = csrf_from(client.get("/funnel").body)
    res = client.post("/funnel/funnel-store/freeze", params: { "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(client.get("/funnel").body).to include("at least 28 days")
  end

  it "the spend block renders 0 without budget_ledger" do
    app, = funnel_app
    body = login(app).get("/funnel").body
    expect(body).to include("tokens today <strong>0</strong>")
  end

  it "the spend block renders the BudgetLedger's current counters when wired" do
    app, = funnel_app(budget: [{ tenant: nil, agent: "funnel-store", by: 1_234 }])
    body = login(app).get("/funnel").body
    expect(body).to include("tokens today <strong>1234</strong>")
  end

  it "the baseline block renders when a baseline exists" do
    cells = [funnel_cell(1, counts: { "greeted" => 1 })]
    app, = build_app(agents: [profile("funnel-store", funnel: FUNNEL_DECL), profile("chef")],
                     funnel_cells: cells)
    # seed the baseline into the same store the page reads:
    app.insika[:funnel_store].set_baseline(
      tenant: nil, agent: "funnel-store",
      record: { "from" => "2026-07-01", "to" => "2026-08-10",
                "stages" => { "greeted" => 30 }, "primary" => "paid",
                "primary_count" => 2, "conversion" => 0.066,
                "window" => "72h", "frozen_at" => "2026-08-15T10:00:00Z" }
    )
    body = login(app).get("/funnel").body
    expect(body).to include("baseline frozen")
    expect(body).to include("2026-07-01")
  end

  it "the session page shows the stage-history block for a declared agent" do
    sess = StoredSession.new(id: "sess-f", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    outcomes = [
      { tenant: nil, agent: "funnel-store", session_id: "sess-f", outcome: "qualified" },
      { tenant: nil, agent: "funnel-store", session_id: "sess-f", outcome: "pix_paid" }
    ]
    app, = funnel_app(outcomes: outcomes, sessions: { "sess-f" => sess })
    body = login(app).get("/sessions/sess-f").body
    expect(body).to include("Stage history")
    expect(body).to include("qualified")
    expect(body).to include("paid")
  end

  it "the session page renders the raw-outcomes note without a declaration" do
    sess = StoredSession.new(id: "sess-r", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    outcomes = [{ tenant: nil, agent: "chef", session_id: "sess-r", outcome: "conversion" }]
    app, = funnel_app(outcomes: outcomes, sessions: { "sess-r" => sess })
    body = login(app).get("/sessions/sess-r").body
    expect(body).to include("no funnel declared — raw outcomes")
    expect(body).to include("conversion")
  end

  it "the funnel nav row is present" do
    app, = build_app
    body = login(app).get("/home").body
    expect(body).to include("Funnel")
  end

  describe "Follow-ups page (RFC-0033 C10)" do
    def followup_app(records:, agents: nil)
      agents ||= [profile("funnel-store", followup: FOLLOWUP_DECL), profile("chef")]
      app, bus = build_app(agents: agents, followup_seed: records,
                           outcomes: [{ tenant: nil, agent: "funnel-store",
                                        session_id: "s-fired", outcome: "conversion" }])
      [app, bus]
    end

    def record(id, at: Time.iso8601("2026-08-15T10:00:00Z"), status: "pending",
               agent: "funnel-store", customer: "c-1", reason: nil,
               session_id: "s-1", blocked_reason: nil, arm: "schedule", tenant: nil)
      { id: id, at: at, status: status, agent: agent, customer: customer,
        reason: reason || "reason-#{id}", session_id: session_id,
        blocked_reason: blocked_reason, arm: arm, tenant: tenant,
        now: Time.iso8601("2026-08-14T12:00:00Z") }
    end

    it "lists only declaring agents and renders pending/fired/blocked rows" do
      records = [
        record("p1", status: "pending"),
        record("f1", status: "fired", session_id: "s-fired"),
        record("b1", status: "blocked", blocked_reason: "frequency")
      ]
      app, = followup_app(records: records)
      body = login(app).get("/followups").body

      expect(body).to include("funnel-store")
      expect(body).not_to match(%r{<h2>chef}) # no declaration -> no block (the filter select lists every agent)
      expect(body).to include("pending")
      expect(body).to include("fired")
      expect(body).to include("blocked")
      expect(body).to include("frequency") # the blocked-reason pill
      expect(body).to include("não quero mais contato") # the policy keywords
    end

    it "renders the A/B card per arm with zero-safe counts" do
      records = [record("f1", status: "fired", session_id: "s-fired", arm: "schedule")]
      app, = followup_app(records: records)
      body = login(app).get("/followups").body

      expect(body).to include("A/B readout")
      expect(body).to include("schedule")
      expect(body).to include("sent")
      expect(body).to include("conversions")
      expect(body).to include("opt-outs")
    end

    it "the opt-out column counts ONLY the arm's own fired customers — never strangers (review fix)" do
      fired = Time.iso8601("2026-08-15T10:00:00Z")
      records = [
        record("f1", status: "fired", session_id: "s-fired", customer: "c-1",
               tenant: "platform", arm: "schedule"),
        # an UNRELATED revocation — other tenant, other customer — must not
        # count against this arm:
        { id: "x1", at: fired, status: "pending", agent: "funnel-store",
          customer: "c-other", session_id: "s-2", reason: "r-x", arm: "schedule",
          now: Time.iso8601("2026-08-14T12:00:00Z"),
          contacts: [
            { tenant: "platform", customer: "c-other", state: "revoked" },
            { tenant: "zed", customer: "c-1", state: "revoked" },
            # the ONE real opt-out: same customer, revoked after her fire
            { tenant: "platform", customer: "c-1", state: "revoked" }
          ] }
      ]
      app, = followup_app(records: records)
      body = login(app).get("/followups").body
      # the arm row ends "…<conversion%> | <opt-outs>" — one real opt-out, and
      # NOT the 3 a global revoked-count would show.
      expect(body).to match(%r{100\.0%<\/td>\s*<td>1</td>})
      expect(body).not_to match(%r{100\.0%<\/td>\s*<td>3</td>})
    end

    it "the revoke POST dispatches :revoke_contact with customer + tenant" do
      app, bus = followup_app(records: [record("p1")])
      client = login(app)
      csrf = csrf_from(client.get("/followups").body)
      res = client.post("/followups/funnel-store/revoke",
                        params: { "customer" => "c-1", "tenant" => "platform", "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/followups?agent=funnel-store")
      expect(bus.last(:revoke_contact).payload).to include(customer: "c-1")
      expect(bus.last(:revoke_contact).meta[:tenant]).to eq("platform")
    end

    it "the cancel POST dispatches :cancel_followup and redirects" do
      app, bus = followup_app(records: [record("p1")])
      client = login(app)
      csrf = csrf_from(client.get("/followups").body)
      res = client.post("/followups/funnel-store/cancel",
                        params: { "id" => "p1", "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/followups?agent=funnel-store")
      expect(bus.last(:cancel_followup).payload).to include(followup_id: "p1")
    end

    it "the empty state renders without declaring agents" do
      app, = build_app(agents: [profile("chef")])
      body = login(app).get("/followups").body
      expect(body).to include("No follow-ups")
    end

    it "the nav row is present" do
      app, = build_app
      body = login(app).get("/home").body
      expect(body).to include("Follow-ups")
    end
  end

  describe "Facts page (RFC-0034 C7)" do
    def facts_app(rows:, sessions: {}, agents: nil)
      agents ||= [profile("funnel-store"), profile("chef")]
      app, bus = build_app(agents: agents, sessions: sessions,
                           proposal_store: seed_facts(rows))
      [app, bus]
    end

    def fact(id, key:, value:, session_ref: "acme:s_1", evidence: [1], status: "pending",
             current_value: nil, note: nil, confidence: nil, tenant: nil)
      { id: id, key: key, value: value, session_ref: session_ref, evidence: evidence,
        status: status, current_value: current_value, note: note, confidence: confidence,
        tenant: tenant }
    end

    it "lists pending proposals with their evidence excerpt" do
      sessions = { "acme:s_1" => StoredSession.new(id: "acme:s_1",
                                                   messages: [
                                                     { "role" => "user", "content" => "hi" },
                                                     { "role" => "user", "content" => "I wear size M" },
                                                     { "role" => "assistant", "content" => "noted" }
                                                   ], vars: nil, updated_at: "t", briefing: nil) }
      app, = facts_app(rows: [fact("p1", key: "size", value: "M", evidence: [1])], sessions: sessions)
      body = login(app).get("/facts").body

      expect(body).to include("size")
      expect(body).to include("M")
      expect(body).to include("I wear size M") # the evidence excerpt, read at request time
      expect(body).to include("Approve &amp; save to memory")
    end

    it "the resolve POST dispatches :resolve_proposal with operator 'studio' and redirects" do
      app, bus = facts_app(rows: [fact("p1", key: "size", value: "M")])
      client = login(app)
      csrf = csrf_from(client.get("/facts").body)
      res = client.post("/facts/resolve", params: { "proposal_id" => "p1", "decision" => "approved",
                                                    "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/facts")
      expect(bus.last(:resolve_proposal).payload).to include(proposal_id: "p1",
                                                             decision: "approved",
                                                             operator: "studio")
    end

    it "the reject note round-trips through the POST" do
      app, bus = facts_app(rows: [fact("p1", key: "size", value: "M")])
      client = login(app)
      csrf = csrf_from(client.get("/facts").body)
      client.post("/facts/resolve", params: { "proposal_id" => "p1", "decision" => "rejected",
                                              "note" => "not durable", "_csrf" => csrf })
      expect(bus.last(:resolve_proposal).payload).to include(note: "not durable")
    end

    it "a stale card shows both values — the proposed one and the operator's current one (E3)" do
      app, = facts_app(rows: [fact("p1", key: "size", value: "M", status: "stale",
                                   current_value: "L")])
      body = login(app).get("/facts").body
      expect(body).to include("M")
      expect(body).to include("L")
      expect(body).to include("Dismiss")
    end

    it "the filter narrows by store scope" do
      rows = [fact("p1", key: "size", value: "M", session_ref: "acme:s_1"),
              fact("p2", key: "color", value: "blue", session_ref: "other:s_1", tenant: "other")]
      app, = facts_app(rows: rows)
      body = login(app).get("/facts?store=acme:c-1").body
      expect(body).to include("size")
      expect(body).not_to include("blue")
    end

    it "without a proposal_store everything renders empty and nothing raises" do
      app, = build_app(agents: [profile("chef")])
      body = login(app).get("/facts").body
      expect(body).to include("distill:")
    end

    it "the nav row is present" do
      app, = build_app
      body = login(app).get("/home").body
      expect(body).to include("Facts")
    end
  end

  describe "Harvest page (RFC-0035 C11)" do
    def harvest_app(candidates: [], promotions: [], runs: [], sessions: {},
                    criterion: nil, negative: nil, agents: nil)
      store = Insika::HarvestStore.new(store: Insika::Stores::Memory.new)
      candidates.each do |c|
        cand = store.create_candidate(
          run_id: c[:run_id] || "run-1", agent: c[:agent] || "store-support",
          name: c[:name], description: c[:description], body: c[:body] || "b",
          rationale: c[:rationale] || "r", origin: c[:origin] || ["acme:s_1"],
          evidence_turns: c[:evidence_turns] || [1], proposer: "utility_model"
        )
        case c[:status]
        when "awaiting"
          store.attach_gate(cand.id, eval_gate: { "passed" => true, "cases" => 7, "passed_cases" => 7 },
                                    conversion_gate: { "passed" => true, "current" => 0.021,
                                                       "baseline" => 0.02, "threshold" => 0.05 },
                                    criterion_sha: "sha256:abc")
          store.mark_awaiting(cand.id)
        when "blocked"
          store.attach_gate(cand.id, eval_gate: { "passed" => true },
                                    conversion_gate: { "passed" => false, "reason" => "no_frozen_baseline" },
                                    criterion_sha: "sha256:abc")
        when "pending"
          nil # stays pending
        end
      end
      promotions.each do |p|
        store.append_promotion(id: p[:id], agent: p[:agent] || "store-support", skill: p[:skill],
                               approver: "studio", snapshot_ref: p[:snapshot_ref] || "snap:1",
                               at: "2026-08-15T10:00:00Z")
        store.append_rollback(promotion_id: p[:id], operator: "studio") if p[:rolled_back]
      end
      runs.each do |r|
        run = store.create_run(agent_id: r[:agent], window: { "last_sessions" => 3 })
        store.complete_run(run.id, candidates: r[:candidates] || 0,
                                   rejected: r[:rejected] || {},
                                   cost: { "spent" => 100 })
      end
      agents ||= [profile("store-support"), profile("chef")]
      app, bus = build_app(agents: agents, sessions: sessions, harvest_store: store,
                           harvest_criterion: criterion, negative_list: negative)
      [app, bus]
    end

    let(:criterion) do
      rule = Insika::Harvest::Criterion::Rule.new(version: 1, metric: "paid", window: "72h",
                                                  threshold: 0.05, min_span: "28d")
      Insika::Harvest::Criterion.new(rule: rule, path: "deployment/CRITERION.md", sha: "sha256:abc")
    end

    it "lists awaiting candidates with their evidence excerpt, read from the session at request time" do
      sessions = { "acme:s_1" => StoredSession.new(id: "acme:s_1",
                                                    messages: [
                                                      { "role" => "user", "content" => "oi" },
                                                      { "role" => "user", "content" => "pix nao caiu" },
                                                      { "role" => "assistant", "content" => "vou verificar" }
                                                    ], vars: nil, updated_at: "t", briefing: nil) }
      app, = harvest_app(candidates: [{ name: "pix-recovery", description: "return for pending PIX",
                                        status: "awaiting", evidence_turns: [1] }],
                         sessions: sessions)
      body = login(app).get("/harvest?agent=store-support").body

      expect(body).to include("pix-recovery")
      expect(body).to include("pix nao caiu") # the excerpt
      expect(body).to include("7/7")          # the eval report line
      expect(body).to include("Promote")
    end

    it "a conversion-blocked candidate renders the ruler's hole with a link to the Funnel page" do
      app, = harvest_app(candidates: [{ name: "phantom", description: "d", status: "blocked" }])
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("no frozen funnel baseline")
      expect(body).to include("/studio/funnel")
    end

    it "the gate POST dispatches :gate_harvest and redirects" do
      app, bus = harvest_app(candidates: [{ name: "fresh", description: "d", status: "pending" }])
      client = login(app)
      csrf = csrf_from(client.get("/harvest").body)
      res = client.post("/harvest/gate", params: { "candidate_id" => "anything", "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/harvest")
      expect(bus.last(:gate_harvest).payload).to include(candidate_id: "anything")
    end

    it "the promote POST dispatches :promote_harvest with operator 'studio' and the note" do
      app, bus = harvest_app(candidates: [{ name: "pix", description: "d", status: "awaiting" }])
      client = login(app)
      csrf = csrf_from(client.get("/harvest").body)
      res = client.post("/harvest/promote",
                        params: { "candidate_id" => "c1", "note" => "go", "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/harvest")
      expect(bus.last(:promote_harvest).payload).to include(candidate_id: "c1",
                                                            operator: "studio", note: "go")
    end

    it "the reject POST dispatches :reject_harvest (a human may always outvote the miner)" do
      app, bus = harvest_app(candidates: [{ name: "pix", description: "d", status: "pending" }])
      client = login(app)
      csrf = csrf_from(client.get("/harvest").body)
      client.post("/harvest/reject", params: { "candidate_id" => "c1", "_csrf" => csrf })
      expect(bus.last(:reject_harvest).payload).to include(candidate_id: "c1", operator: "studio")
    end

    it "the rollback POST dispatches :rollback_harvest with the snapshot ref and reason" do
      app, bus = harvest_app(promotions: [{ id: "p1", skill: "pix" }])
      client = login(app)
      csrf = csrf_from(client.get("/harvest").body)
      res = client.post("/harvest/rollback",
                        params: { "snapshot_ref" => "snap:1", "reason" => "audit", "_csrf" => csrf })
      expect(res.headers["location"]).to include("/studio/harvest")
      expect(bus.last(:rollback_harvest).payload).to include(snapshot_ref: "snap:1", reason: "audit")
    end

    it "the promoted list renders rows and rollback buttons; rolled-back rows render the stamp" do
      app, = harvest_app(promotions: [
                           { id: "p1", skill: "live-skill" },
                           { id: "p2", skill: "dead-skill", rolled_back: true }
                         ])
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("live-skill")
      expect(body).to include("Rollback")
      expect(body).to include("dead-skill")
      expect(body).to include("rolled back")
    end

    it "the negative-list block renders the rules with their rejection counts from the runs" do
      negative = Insika::Harvest::NegativeList.parse([
                                                       { "rule" => "no-competitor-prices", "pattern" => "concorrente" }
                                                     ])
      app, = harvest_app(negative: negative,
                         runs: [{ agent: "store-support", rejected: { "no-competitor-prices" => 2 } }])
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("no-competitor-prices")
      expect(body).to include("rejected: 2")
    end

    it "the ruler block shows the criterion's metric, window, threshold and sha" do
      app, = harvest_app(criterion: criterion)
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("paid")
      expect(body).to include("72h")
      expect(body).to include("sha256:abc")
    end

    it "the agent filter narrows EVERY list — store A's page never shows store B's candidates (the review fix)" do
      app, = harvest_app(candidates: [
                           { name: "a-skill", description: "d", status: "awaiting", agent: "store-support" },
                           { name: "b-skill", description: "d", status: "awaiting", agent: "store-b" }
                         ])
      body_a = login(app).get("/harvest?agent=store-support").body
      expect(body_a).to include("a-skill")
      expect(body_a).not_to include("b-skill")
    end

    it "the evidence excerpt renders ONE message per index — an index valid in one origin session is not replayed against the others (the review fix)" do
      sessions = {
        "acme:s_1" => StoredSession.new(id: "acme:s_1",
                                        messages: [
                                          { "role" => "user", "content" => "msg-1" },
                                          { "role" => "user", "content" => "msg-2" },
                                          { "role" => "assistant", "content" => "msg-3" }
                                        ], vars: nil, updated_at: "t", briefing: nil),
        "acme:s_2" => StoredSession.new(id: "acme:s_2",
                                        messages: [
                                          { "role" => "user", "content" => "other-1" }
                                        ], vars: nil, updated_at: "t", briefing: nil)
      }
      app, = harvest_app(candidates: [{ name: "multi", description: "d", status: "awaiting",
                                        origin: %w[acme:s_1 acme:s_2], evidence_turns: [1] }],
                         sessions: sessions)
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("msg-2")       # the evidence message, from the session where the index is valid
      expect(body).not_to include("other-1") # the same index is NOT replayed against the other conversation
    end

    it "without any store everything renders empty and nothing raises" do
      app, = build_app(agents: [profile("chef")])
      body = login(app).get("/harvest?agent=store-support").body
      expect(body).to include("No harvest")
    end

    it "the nav row is present" do
      app, = build_app
      body = login(app).get("/home").body
      expect(body).to include("Harvest")
    end
  end
end
