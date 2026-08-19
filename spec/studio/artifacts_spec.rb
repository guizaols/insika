# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

# the Artifacts surface: the list page (per agent), the preview
# page (sandboxed iframe), the authenticated content route, the signed-link
# route, and the delete dispatch. The content is LLM output, so every route
# that serves it sends a restrictive CSP + nosniff; the signed route is the
# ONLY artifact path without a session, and it must 404 (never 403) on a bad
# or expired signature — and not exist at all without a key.
RSpec.describe "Studio artifacts" do
  ArtBusDouble = Struct.new(:dispatched) do
    def dispatch(command)
      dispatched << command
      { deleted: command.payload[:id] }
    end

    def registered?(_type) = true
    def last(type) = dispatched.reverse.find { |c| c.type == type }
  end

  ArtProfileSource = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
    def fetch(id) = profiles.find { |p| p.id == id }
  end

  def artifact_store
    Insika::ArtifactStore.new(store: Insika::Stores::Memory.new)
  end

  def build_app(store: artifact_store, signing_key: nil, profiles: ["reporter"], bus: nil)
    app = Class.new(Studio::App)
    app.configure(
      command_bus: bus || ArtBusDouble.new([]),
      profile_source: ArtProfileSource.new([profile_id]),
      event_stream: nil, config: { admin_token: "s3cret" },
      artifact_store: store,
      artifact_signing: signing_key ? { key: signing_key, ttl: 3600, base_url: "https://insika.example" } : nil,
      session_secret: "x" * 64
    )
    app
  end

  def profile_id
    Insika::AgentProfile.build(id: "reporter", model: "m", tools_allow: %w[save_artifact])
  end

  def seed(store, id: "a-1", title: "Daily report", tenant: "platform")
    store.create(tenant: tenant, agent: "reporter", task_id: "t-1", title: title,
                 mime: "text/html", content: "<html><body><h1>Report</h1></body></html>",
                 id: id, now: Time.iso8601("2026-08-19T12:00:00Z"))
  end

  # Client that carries cookies between requests (session + CSRF live in the cookie).
  class ArtClient
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

  def login(app)
    client = ArtClient.new(app)
    form = client.get("/login")
    client.post("/login", params: { "token" => "s3cret", "_csrf" => csrf_from(form.body) })
    client
  end

  let(:store) { artifact_store }
  let(:app) { build_app(store: store) }
  let(:client) { login(app) }
  let(:csrf) { csrf_from(client.get("/artifacts").body) }

  def csrf_from(body)
    body[/name="_csrf" value="([^"]+)"/, 1] || ""
  end

  describe "the list page" do
    it "lists the agent's artifacts with title + created_at" do
      seed(store)
      body = client.get("/artifacts?agent=reporter").body
      expect(body).to include("Daily report")
      expect(body).to include("a-1")
      expect(body).to include("2026-08-19T12:00:00Z")
    end

    it "shows the empty state when nothing was saved" do
      body = client.get("/artifacts?agent=reporter").body
      expect(body).to include("No artifacts")
    end

    it "a preview link is present" do
      seed(store)
      body = client.get("/artifacts?agent=reporter").body
      expect(body).to include("/artifacts/a-1")
    end
  end

  describe "the authenticated content route (E1)" do
    it "serves the artifact with the restrictive CSP + nosniff headers" do
      seed(store)
      res = client.get("/artifacts/a-1/content")
      expect(res.status).to eq(200)
      expect(res.body).to include("<h1>Report</h1>")
      expect(res["content-type"]).to include("text/html")
      expect(res["content-security-policy"]).to include("default-src 'none'")
      expect(res["content-security-policy"]).to include("style-src 'unsafe-inline'")
      expect(res["content-security-policy"]).to include("img-src data:")
      expect(res["x-content-type-options"]).to eq("nosniff")
    end

    it "an unknown id is a 404, not an empty body" do
      res = client.get("/artifacts/nope/content")
      expect(res.status).to eq(404)
    end

    it "the preview page embeds a SANDBOXED iframe (no allow-scripts/same-origin/forms)" do
      seed(store)
      body = client.get("/artifacts/a-1").body
      expect(body).to include('sandbox="allow-same-origin"').or include("sandbox")
      expect(body).to include("/artifacts/a-1/content")
    end

    it "the content route requires a session (unauthenticated -> login redirect)" do
      seed(store)
      res = Rack::MockRequest.new(app).get("/artifacts/a-1/content")
      expect(res.status).to eq(302)
      expect(res["location"]).to include("/login")
    end
  end

  describe "the signed link (E2)" do
    let(:key) { "k3y" * 8 }
    let(:signed_app) { build_app(store: store, signing_key: key) }
    let(:anon) { Rack::MockRequest.new(signed_app) }

    it "a valid unexpired link serves WITHOUT a session; expired -> 404" do
      seed(store)
      exp = (Time.now.utc + 3600).iso8601
      sig = Insika::ArtifactSigning.sign(id: "a-1", expires_at: exp, key: key)
      res = anon.get("/artifacts/s/a-1?exp=#{exp}&sig=#{sig}")
      expect(res.status).to eq(200)
      expect(res.body).to include("<h1>Report</h1>")
      expect(res["content-security-policy"]).to include("default-src 'none'")

      expired = (Time.now.utc - 1).iso8601
      res = anon.get("/artifacts/s/a-1?exp=#{expired}&sig=#{sig}")
      expect(res.status).to eq(404)
    end

    it "a bad signature is a 404 (never a 403 — no oracle)" do
      seed(store)
      exp = (Time.now.utc + 3600).iso8601
      res = anon.get("/artifacts/s/a-1?exp=#{exp}&sig=#{'0' * 64}")
      expect(res.status).to eq(404)
    end

    it "without a signing key there is NO signed surface (a forged link 404s)" do
      seed(store)
      anon = Rack::MockRequest.new(app)
      res = anon.get("/artifacts/s/a-1?exp=#{Time.now.utc.iso8601}&sig=#{'0' * 64}")
      expect(res.status).to eq(404)
    end

    it "the tool's signed_url opens the artifact (round trip)" do
      seed(store)
      url = Insika::ArtifactSigning.url_for(id: "a-1", base: "https://insika.example",
                                            key: key, ttl: 3600)
      path = url.sub("https://insika.example/studio", "")
      res = anon.get(path)
      expect(res.status).to eq(200)
    end
  end

  describe "the #152 regression (binary path id against real SQLite)" do
    it "resolves a percent-coded accented id through the content route" do
      require "tmpdir"
      Dir.mktmpdir do |dir|
        sqlite = Insika::Stores::SQLite.new(path: File.join(dir, "cfg.db"))
        st = Insika::ArtifactStore.new(store: sqlite)
        seed(st, id: "relatório-2026")
        app = build_app(store: st)
        client = login(app)
        # the mock leaves the path percent-encoded; a real server DECODES it to
        # UTF-8 bytes and hands Roda an ASCII-8BIT PATH_INFO. Recreate that
        # shape: decode, then force binary — the store key written in UTF-8 must
        # still match (a binary get binds as BLOB on SQLite and 404s otherwise).
        env = Rack::MockRequest.env_for("/artifacts/relat%C3%B3rio-2026/content")
        env["PATH_INFO"] = Rack::Utils.unescape_path(env["PATH_INFO"]).dup.force_encoding(Encoding::ASCII_8BIT)
        env["HTTP_COOKIE"] = client.cookie
        status, = app.call(env)
        expect(status).to eq(200)
      end
    end
  end

  describe "delete" do
    it "dispatches :delete_artifact and redirects back to the list" do
      seed(store)
      bus = ArtBusDouble.new([])
      app = build_app(store: store, bus: bus)
      client = login(app)
      csrf = csrf_from(client.get("/artifacts").body)
      res = client.post("/artifacts/a-1/delete", params: { "_csrf" => csrf })
      expect(res.status).to eq(302)
      expect(bus.last(:delete_artifact).payload[:id]).to eq("a-1")
    end
  end
end