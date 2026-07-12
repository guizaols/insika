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

  BusDouble = Struct.new(:dispatched) do
    def dispatch(command)
      dispatched << command
      command.type == :create_session ? SessionDouble.new("sess-new") : { task_id: "task-1" }
    end
  end

  # ProfileSource duck-type: `all` (lista) + `ids`.
  ProfileSourceDouble = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
  end

  def profile(id, model: "deepseek-chat", provider: :deepseek, memory: true,
              tools_allow: %w[menu calc], skills: %w[pedido])
    Harness::AgentProfile.build(id: id, model: model, provider: provider,
                                memory: memory, tools_allow: tools_allow, skills: skills)
  end

  def build_app(admin_token: "s3cret", agents: [profile("bia"), profile("chef")])
    bus = BusDouble.new([])
    app = Class.new(Studio::App)
    app.configure(
      command_bus: bus, profile_source: ProfileSourceDouble.new(agents),
      event_stream: nil, config: { admin_token: admin_token },
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
end
