# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../studio/app"

# Studio (Fase 4, Etapa E) — app Roda montado sob /studio. Exercita auth por
# cookie (D7, fail-closed), CSRF nos POSTs, CSP estrita (D8), serving de assets
# versionados e as páginas login/agents/playground. Doubles no lugar do runtime:
# o Studio só LÊ o ProfileSource e despacha Commands no bus (nunca escreve em
# store direto) — a mesma superfície do Server::App.
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

  # ProfileSource duck-type: `all` (lista) + `ids` + `fetch`.
  ProfileSourceDouble = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
    def fetch(id) = profiles.find { |p| p.id == id }
  end

  # Stores de leitura da Etapa F (só o que as páginas consomem).
  SkillEntry = Struct.new(:name, :description, keyword_init: true)
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

  def profile(id, model: "deepseek-chat", provider: :deepseek, memory: true,
              tools_allow: %w[menu calc], skills: %w[pedido], prompt_files: [])
    Harness::AgentProfile.build(id: id, model: model, provider: provider,
                                memory: memory, tools_allow: tools_allow,
                                skills: skills, prompt_files: prompt_files)
  end

  def build_app(admin_token: "s3cret", agents: [profile("bia"), profile("chef")],
                agent_files: {}, skills: [SkillEntry.new(name: "pedido", description: "faz pedido")],
                stored_skills: {}, tools: [SkillEntry.new(name: "menu", description: "cardápio")],
                memory: {}, sessions: {}, settings: nil, llm_providers: [],
                mcp_instances: [], system_files: {})
    bus = BusDouble.new([])
    app = Class.new(Studio::App)
    # Stores de config da Etapa G: REAIS sobre um ConfigStore em memória (o
    # Studio lê deles ao renderizar; escreve via os Commands do bus). Semeados
    # pelos params para exercitar o read-path de settings/LLM/MCP/system-files.
    cfg = Harness::ConfigStore.new(store: Harness::Stores::Memory.new)
    settings_store = Harness::SettingsStore.new(config_store: cfg)
    settings_store.update(settings) if settings
    provider_store = Harness::LLMProviderStore.new(config_store: cfg)
    llm_providers.each { |p| provider_store.upsert(p) }
    mcp_store = Harness::McpStore.new(config_store: cfg)
    mcp_instances.each { |m| mcp_store.upsert(m) }
    system_file_store = Harness::SystemFileStore.new(config_store: cfg)
    system_files.each { |name, content| system_file_store.write(name, content) }
    app.configure(
      command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
      event_stream: nil, config: { admin_token: admin_token },
      agent_file_store: AgentFileStoreDouble.new(agent_files),
      skill_store: SkillStoreDouble.new(stored_skills),
      skill_catalog: SkillCatalogDouble.new(skills),
      tool_catalog: ToolCatalogDouble.new(tools),
      memory_store: MemoryStoreDouble.new(memory),
      session_store: SessionStoreDouble.new(sessions),
      settings_store: settings_store, llm_provider_store: provider_store,
      mcp_store: mcp_store, system_file_store: system_file_store,
      session_secret: "x" * 64
    )
    [app, bus]
  end

  # Cliente que carrega cookies entre requests (sessão + CSRF vivem no cookie).
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

  # Faz o login completo (GET p/ cookie+token, POST com o token) e devolve o
  # client autenticado.
  def login(app, token: "s3cret")
    client = Client.new(app)
    form = client.get("/login")
    csrf = csrf_from(form.body)
    client.post("/login", params: { "token" => token, "_csrf" => csrf })
    client
  end

  # --- Auth / fail-closed --------------------------------------------------

  it "mostra o login sem sessão (GET /login = 200 com form e CSRF)" do
    app, = build_app
    res = Client.new(app).get("/login")
    expect(res.status).to eq(200)
    expect(res.body).to include('name="token"')
    expect(res.body).to include('name="_csrf"')
  end

  it "redireciona rotas protegidas para /studio/login sem sessão (fail-closed)" do
    app, = build_app
    res = Client.new(app).get("/agents")
    expect(res.status).to eq(302)
    expect(res.headers["location"]).to eq("/studio/login")
  end

  it "autentica com o token correto e passa a servir as páginas" do
    app, = build_app
    client = login(app, token: "s3cret")
    res = client.get("/agents")
    expect(res.status).to eq(200)
    expect(res.body).to include("bia")
    expect(res.body).to include("chef")
  end

  it "recusa token incorreto (401, sem sessão)" do
    app, = build_app
    client = Client.new(app)
    csrf = csrf_from(client.get("/login").body)
    res = client.post("/login", params: { "token" => "errado", "_csrf" => csrf })
    expect(res.status).to eq(401)
    # sessão não foi marcada: rota protegida ainda redireciona
    expect(client.get("/agents").status).to eq(302)
  end

  it "é fail-closed quando não há token configurado (login nunca valida)" do
    app, = build_app(admin_token: "")
    client = Client.new(app)
    csrf = csrf_from(client.get("/login").body)
    res = client.post("/login", params: { "token" => "qualquer", "_csrf" => csrf })
    expect(res.status).to eq(401)
  end

  it "faz logout limpando a sessão" do
    app, = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    expect(client.post("/logout", params: { "_csrf" => csrf }).status).to eq(302)
    expect(client.get("/agents").status).to eq(302) # sessão limpa → volta ao login
  end

  # --- CSRF ----------------------------------------------------------------

  it "bloqueia POST sem token CSRF (403)" do
    app, = build_app
    # sessão obtida por GET, mas POST sem _csrf
    client = Client.new(app)
    client.get("/login")
    res = client.post("/login", params: { "token" => "s3cret" })
    expect(res.status).to eq(403)
  end

  # --- CSP / headers -------------------------------------------------------

  it "envia CSP estrita 'self' (sem unsafe-inline) e nosniff" do
    app, = build_app
    res = Client.new(app).get("/login")
    csp = res.headers["content-security-policy"]
    expect(csp).to include("script-src 'self'")
    expect(csp).to include("style-src 'self'")
    expect(csp).not_to include("unsafe-inline")
    expect(res.headers["x-content-type-options"]).to eq("nosniff")
  end

  # --- Assets --------------------------------------------------------------

  it "serve o bundle versionado com content-type correto" do
    app, = build_app
    res = Client.new(app).get("/assets/dist/application.css")
    expect(res.status).to eq(200)
    expect(res.headers["content-type"]).to include("text/css")
  end

  it "não escapa do dir de dist (path traversal → 404)" do
    app, = build_app
    res = Client.new(app).get("/assets/dist/..%2f..%2fapp.rb")
    expect(res.status).to eq(404)
  end

  # --- Playground ----------------------------------------------------------

  it "despacha send_message pelo bus e redireciona (nada de escrita direta)" do
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

  it "cria uma sessão nova quando session_id vem em branco" do
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

  it "playground GET lista os agentes no seletor" do
    app, = build_app
    client = login(app)
    res = client.get("/playground?agent=chef")
    expect(res.status).to eq(200)
    expect(res.body).to include('value="chef"')
    expect(res.body).to include('data-controller="live-transcript"')
  end

  it "escapa conteúdo dinâmico exatamente uma vez (sem duplo-escape, XSS-safe)" do
    app, = build_app(agents: [profile("bia", model: "modelo&<x>")])
    client = login(app)
    body = client.get("/agents").body
    expect(body).to include("modelo&amp;&lt;x&gt;")   # escapado 1×
    expect(body).not_to include("&amp;amp;")           # NÃO duplo-escapado
    expect(body).not_to include("modelo&<x>")          # NÃO cru
  end

  it "responde 404 amigável em rota autenticada desconhecida" do
    app, = build_app
    client = login(app)
    res = client.get("/inexistente")
    expect(res.status).to eq(404)
    expect(res.body).to include("404")
  end

  it "playground manda tenant = agente no send_message (memória por-agente)" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/playground").body)
    client.post("/playground", params: { "agent" => "chef", "session_id" => "s1",
                                          "message" => "oi", "_csrf" => csrf })
    expect(bus.last(:send_message).meta[:tenant]).to eq("chef")
  end

  it "a app-bar tem os links de skills e tools (Etapa F)" do
    app, = build_app
    body = login(app).get("/agents").body
    expect(body).to include('href="/studio/skills"')
    expect(body).to include('href="/studio/tools"')
  end

  # --- Agents (detail) — task 15/17 ----------------------------------------

  it "renderiza o detalhe do agente com config, prompts, skills, memória e histórico" do
    app, = build_app
    res = login(app).get("/agents/bia")
    expect(res.status).to eq(200)
    %w[config prompts skills memoria historico].each { |a| expect(res.body).to include("id=\"#{a}\"") }
    expect(res.body).to include('name="model"')
    expect(res.body).to include('data-controller="code-editor"')
  end

  it "404 no detalhe de agente inexistente" do
    app, = build_app
    expect(login(app).get("/agents/nao-existe").status).to eq(404)
  end

  # Regressão (encontrada rodando de verdade): o matcher String do Roda entrega
  # o segmento de path em ASCII-8BIT; um `get` no store SQLite com chave binária
  # não casa a chave gravada em UTF-8 (bind como BLOB) e o detalhe 404-ava. A
  # borda normaliza para UTF-8 (`utf8`). Doubles não reproduzem (String#== é
  # encoding-agnóstico p/ ASCII) — este teste usa SQLite real + PATH_INFO binário.
  it "resolve id de path binário contra o store SQLite (regressão de encoding)" do
    require "tmpdir"
    Dir.mktmpdir do |dir|
      store = Harness::Stores::SQLite.new(path: File.join(dir, "cfg.db"))
      src = Harness::StoredProfileSource.new(config_store: Harness::ConfigStore.new(store: store))
      src.put(Harness::AgentProfile.build(id: "bia", model: "m", provider: :deepseek, memory: true))
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

  it "config despacha update_agent com memory bool e limits int" do
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

  it "config sem checkbox de memória grava memory=false" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/config", params: { "model" => "x", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload[:memory]).to be(false)
  end

  it "gravar prompt NOVO também o adiciona a prompt_files" do
    app, bus = build_app # bia tem prompt_files: []
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts", params: {
                  "file" => "IDENTITY.md", "content" => "# Eu", "_csrf" => csrf
                })
    expect(bus.last(:write_agent_file).payload).to include(agent_id: "bia", file: "IDENTITY.md")
    expect(bus.last(:update_agent).payload[:prompt_files]).to eq(["IDENTITY.md"])
  end

  it "gravar prompt JÁ referenciado não redispara update_agent" do
    app, bus = build_app(agents: [profile("bia", prompt_files: ["IDENTITY.md"])])
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts", params: {
                  "file" => "IDENTITY.md", "content" => "# Eu 2", "_csrf" => csrf
                })
    expect(bus.types).to include(:write_agent_file)
    expect(bus.types).not_to include(:update_agent)
  end

  it "remover prompt despacha delete_agent_file e tira de prompt_files" do
    app, bus = build_app(agents: [profile("bia", prompt_files: %w[IDENTITY.md SOUL.md])])
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts/delete", params: { "file" => "SOUL.md", "_csrf" => csrf })
    expect(bus.last(:delete_agent_file).payload).to include(agent_id: "bia", file: "SOUL.md")
    expect(bus.last(:update_agent).payload[:prompt_files]).to eq(["IDENTITY.md"])
  end

  it "restaurar prompt despacha restore_agent_file com version" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/prompts/restore", params: {
                  "file" => "IDENTITY.md", "version" => "2", "_csrf" => csrf
                })
    expect(bus.last(:restore_agent_file).payload).to include(agent_id: "bia", file: "IDENTITY.md", version: "2")
  end

  it "skills 'todas' despacha update_agent com skills nil" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/skills", params: { "all_skills" => "1", "_csrf" => csrf })
    expect(bus.last(:update_agent).payload).to include(skills: nil)
  end

  it "skills subconjunto despacha update_agent com a lista marcada" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/agents/bia").body)
    client.post("/agents/bia/skills", params: { "skills" => ["pedido"], "_csrf" => csrf })
    expect(bus.last(:update_agent).payload).to include(skills: ["pedido"])
  end

  it "memória: fato/esquecer/nota despacham escopados por tenant = id do agente" do
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

  it "detalhe mostra os fatos da memória do agente (tenant = id)" do
    fact = Harness::MemoryStore::Fact.new(key: "nome", value: "Ana", updated_at: "t")
    app, = build_app(memory: { "bia" => { facts: [fact], notes: [] } })
    body = login(app).get("/agents/bia").body
    expect(body).to include("nome")
    expect(body).to include("Ana")
  end

  # --- Skills (index + editor) — task 16 -----------------------------------

  it "lista as skills e a matriz de agentes" do
    app, = build_app
    body = login(app).get("/skills").body
    expect(body).to include("pedido")               # skill do catálogo
    expect(body).to include('name="agent_ids[]"')   # matriz
  end

  it "editor de skill nova traz o template com frontmatter" do
    app, = build_app
    body = login(app).get("/skills/new").body
    expect(body).to include('data-controller="code-editor"')
    expect(body).to include("name:")
  end

  it "editor de skill existente traz o conteúdo do store" do
    app, = build_app(stored_skills: { "pedido" => "---\nname: pedido\n---\ncorpo autorado" })
    body = login(app).get("/skills/pedido").body
    expect(body).to include("corpo autorado")
  end

  it "salvar skill despacha write_skill" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/skills/new").body)
    res = client.post("/skills", params: { "name" => "reembolso", "content" => "---\nname: reembolso\n---\nx", "_csrf" => csrf })
    expect(res.status).to eq(302)
    expect(bus.last(:write_skill).payload).to include(name: "reembolso")
  end

  it "aplicar skill aos agentes despacha set_skill_agents com agent_ids" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/skills").body)
    client.post("/skills/pedido/agents", params: { "agent_ids" => %w[bia chef], "_csrf" => csrf })
    cmd = bus.last(:set_skill_agents)
    expect(cmd.payload[:name]).to eq("pedido")
    expect(cmd.payload[:agent_ids]).to eq(%w[bia chef])
  end

  # --- Tools (matriz) — task 16 --------------------------------------------

  it "lista a matriz de tools por agente" do
    app, = build_app
    body = login(app).get("/tools").body
    expect(body).to include("menu")               # tool do catálogo
    expect(body).to include('name="all_tools"')
  end

  it "tools 'todas' despacha set_agent_tools com allow nil" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/tools").body)
    client.post("/tools/bia", params: { "all_tools" => "1", "_csrf" => csrf })
    expect(bus.last(:set_agent_tools).payload).to include(id: "bia", allow: nil)
  end

  it "tools subconjunto despacha set_agent_tools com a lista e preserva o deny" do
    app, bus = build_app(agents: [profile("bia", tools_allow: %w[menu calc])])
    client = login(app)
    csrf = csrf_from(client.get("/tools").body)
    client.post("/tools/bia", params: { "tools" => ["menu"], "_csrf" => csrf })
    cmd = bus.last(:set_agent_tools)
    expect(cmd.payload[:allow]).to eq(["menu"])
    expect(cmd.payload).to have_key(:deny)
  end

  # --- Histórico (viewer read-only) — task 17 ------------------------------

  it "viewer de sessão renderiza o transcript read-only" do
    sess = StoredSession.new(id: "sess-xyz", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "oi" },
                                        { "role" => "assistant", "content" => "olá!" }])
    app, = build_app(sessions: { "sess-xyz" => sess })
    body = login(app).get("/sessions/sess-xyz").body
    expect(body).to include("olá!")
    expect(body).to include("continuar no playground")
  end

  it "404 em sessão inexistente" do
    app, = build_app
    expect(login(app).get("/sessions/nope").status).to eq(404)
  end

  it "o histórico do detalhe lista as conversas recentes" do
    sess = StoredSession.new(id: "sess-abc123456789", updated_at: "t", messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-abc123456789" => sess })
    body = login(app).get("/agents/bia").body
    expect(body).to include("/studio/sessions/sess-abc123456789")
  end

  # --- Settings (task 18) --------------------------------------------------

  it "a app-bar tem os links da Etapa G (mcp/sistema/chats/settings)" do
    app, = build_app
    body = login(app).get("/agents").body
    %w[/studio/mcp /studio/system-files /studio/chats /studio/settings].each do |href|
      expect(body).to include("href=\"#{href}\"")
    end
  end

  it "settings renderiza os defaults e despacha update_settings com tipos nativos" do
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

  it "settings sem checkbox de streaming manda streaming=false" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings", params: { "turn_timeout" => "90", "_csrf" => csrf })
    expect(bus.last(:update_settings).payload[:patch]["streaming"]).to be(false)
  end

  it "settings lista providers com a chave MASCARADA (nunca plaintext)" do
    app, = build_app(llm_providers: [{ "api" => "deepseek", "api_key" => "sk-secret", "models" => %w[deepseek-chat] }])
    body = login(app).get("/settings").body
    expect(body).to include("deepseek")
    expect(body).to include("__OCULTO__")
    expect(body).not_to include("sk-secret")
  end

  it "salvar provider despacha upsert_llm_provider com models parseados" do
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

  it "remover provider despacha delete_llm_provider" do
    app, bus = build_app(llm_providers: [{ "api" => "openai", "api_key" => "sk-1" }])
    client = login(app)
    csrf = csrf_from(client.get("/settings").body)
    client.post("/settings/providers/delete", params: { "api" => "openai", "_csrf" => csrf })
    expect(bus.last(:delete_llm_provider).payload).to include(api: "openai")
  end

  # --- MCP (task 18) -------------------------------------------------------

  it "mcp lista instâncias com env MASCARADO e despacha upsert_mcp (env por linhas)" do
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

  it "remover instância MCP despacha delete_mcp" do
    app, bus = build_app(mcp_instances: [{ "name" => "tavily" }])
    client = login(app)
    csrf = csrf_from(client.get("/mcp").body)
    client.post("/mcp/delete", params: { "name" => "tavily", "_csrf" => csrf })
    expect(bus.last(:delete_mcp).payload).to include(name: "tavily")
  end

  # --- System-files (task 19) ----------------------------------------------

  it "system-files lista arquivos globais e usa o island code-editor" do
    app, = build_app(system_files: { "HOUSE.md" => "regras da casa" })
    body = login(app).get("/system-files").body
    expect(body).to include("HOUSE.md")
    expect(body).to include("regras da casa")
    expect(body).to include('data-controller="code-editor"')
  end

  it "salvar arquivo de sistema despacha write_system_file" do
    app, bus = build_app
    client = login(app)
    csrf = csrf_from(client.get("/system-files").body)
    client.post("/system-files", params: { "file" => "RULES.md", "content" => "# Regras", "_csrf" => csrf })
    expect(bus.last(:write_system_file).payload).to include(file: "RULES.md", content: "# Regras")
  end

  it "remover/restaurar arquivo de sistema despacham seus Commands" do
    app, bus = build_app(system_files: { "H.md" => "x" })
    client = login(app)
    csrf = csrf_from(client.get("/system-files").body)
    client.post("/system-files/delete", params: { "file" => "H.md", "_csrf" => csrf })
    client.post("/system-files/restore", params: { "file" => "H.md", "version" => "0", "_csrf" => csrf })
    expect(bus.last(:delete_system_file).payload).to include(file: "H.md")
    expect(bus.last(:restore_system_file).payload).to include(file: "H.md", version: "0")
  end

  # --- Chats (task 19) -----------------------------------------------------

  it "chats lista as conversas e linka pro viewer" do
    sess = StoredSession.new(id: "sess-chat-000001", updated_at: "t",
                             messages: [{ "role" => "user", "content" => "oi" }])
    app, = build_app(sessions: { "sess-chat-000001" => sess })
    body = login(app).get("/chats").body
    expect(body).to include("/studio/sessions/sess-chat-000001")
  end

  it "chats vazio mostra empty-state" do
    app, = build_app
    body = login(app).get("/chats").body
    expect(body).to include("Nenhuma conversa")
  end
end
