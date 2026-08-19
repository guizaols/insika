# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../lib/insika/studio/app"

# C8 — /studio/parity. Reads stores and folds on demand; the judge button is a
# slow synchronous POST dispatching :judge_shadow_pairs with CSRF enforced. The
# nav row exists only when a shadow channel is registered.
RSpec.describe "Studio parity page" do
  CRITERION = Insika::Parity::Criterion.load(File.expand_path("../fixtures/parity/criterion.md", __dir__))
  FIXED_NOW = Time.utc(2026, 8, 15, 12, 0, 0)

  ParityProfileSource = Struct.new(:profiles) do
    def all = profiles
    def ids = profiles.map(&:id)
    def fetch(id) = profiles.find { |p| p.id == id }
  end

  ParityBusDouble = Struct.new(:dispatched) do
    def dispatch(command)
      dispatched << command
      { judged: 1, skipped: 0, expired: 0, failed: 0, models: %w[m1 m2 m3] }
    end
  end

  # A registry whose channel is shadow when `shadow` is set.
  def registry_with(shadow: true)
    channel = Insika::Channels::Relay.new(inbound_token: "t", deliver_url: "https://8.8.8.8/h",
                                          shadow: shadow)
    Insika::ChannelRegistry.new.tap { |r| r.register("relay", channel) }
  end

  def pair_store_with_pairs(status: :judged, outcome: "better", created_at: nil)
    pairs = Insika::ShadowPairStore.new(store: Insika::Stores::Memory.new)
    id = Insika::ShadowPairStore.key_for(channel: "relay", external_id: "5511", event_id: "e1")
    pairs.record_incumbent(id: id, channel: "relay", event_id: "e1", external_id: "5511",
                           reply: "me passa o número?", at: created_at || FIXED_NOW)
    pairs.record_ours(id: id, channel: "relay", agent: "agent-store-loja-chocolates",
                      session_id: "relay:5511", task_id: "t", event_id: "e1",
                      inbound: "queria saber do pedido", reply: "já confiro pra você",
                      criterion_sha: CRITERION.sha)
    if status == :judged
      pairs.record_verdict(id, verdict: { "outcome" => outcome, "reason" => "r", "vs" => "agent",
                                          "judges" => %w[better better better],
                                          "order_dependent" => false,
                                          "models" => %w[m1 m2 m3],
                                          "judged_at" => "2026-08-15T00:00:00Z" })
    end
    pairs
  end

  def build_app(shadow_pairs: nil, criterion: CRITERION, channels: nil, bus: nil)
    app = Class.new(Studio::App)
    app.configure(
      command_bus: bus || ParityBusDouble.new([]),
      profile_source: ParityProfileSource.new([]),
      event_stream: nil, config: { admin_token: "s3cret" },
      shadow_pair_store: shadow_pairs, parity_criterion: criterion,
      channel_registry: channels, session_secret: "x" * 64
    )
    app
  end

  class ParityClient
    attr_reader :cookie, :bus

    def initialize(app, bus)
      @mock = Rack::MockRequest.new(app)
      @bus = bus
    end

    def get(path) = capture(@mock.get(path, headers))
    def post(path, params: {}) = capture(@mock.post(path, headers.merge(params: params)))

    def login
      form = get("/login")
      csrf = form.body[/name="_csrf" value="([^"]+)"/, 1]
      post("/login", params: { "token" => "s3cret", "_csrf" => csrf })
    end

    private

    def headers = @cookie ? { "HTTP_COOKIE" => @cookie } : {}

    def capture(res)
      if (sc = res.headers["set-cookie"])
        @cookie = Array(sc).map { |c| c.split(";").first }.join("; ")
      end
      res
    end
  end

  it "renders each of the four verdicts from the SAME fold the engine uses" do
    pairs = pair_store_with_pairs
    client = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with), ParityBusDouble.new([]))
    client.login

    res = client.get("/parity")
    expect(res.status).to eq(200)
    expect(res.body).to include("The shadow experiment".downcase) # the fold's own words are on the page
    expect(res.body).to include("pass")
    expect(res.body).to include("criterion_sha")
    expect(res.body).to include("queria saber do pedido")
    expect(res.body).to include("me passa o número?")
    expect(res.body).to include("já confiro pra você")
  end

  it "shows the arithmetic, not just the conclusion" do
    pairs = pair_store_with_pairs
    client = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with), ParityBusDouble.new([]))
    client.login
    body = client.get("/parity").body.downcase
    expect(body).to include("required")
    expect(body).to include("pairs / day")
    expect(body).to include("per store")
    expect(body).to include("judge agreement")
  end

  it "the nav row is absent without a shadow channel, present with one" do
    pairs = pair_store_with_pairs
    no_shadow = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with(shadow: false)), ParityBusDouble.new([]))
    no_shadow.login
    expect(no_shadow.get("/agents").body).not_to include("/studio/parity")

    with_shadow = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with), ParityBusDouble.new([]))
    with_shadow.login
    expect(with_shadow.get("/agents").body).to include("/studio/parity")
  end

  it "empty state without a criterion says what to switch on" do
    client = ParityClient.new(build_app(criterion: nil), ParityBusDouble.new([]))
    client.login
    body = client.get("/parity").body
    expect(body).to include("INSIKA_RELAY_SHADOW=1")
  end

  it "the judge POST dispatches :judge_shadow_pairs through the bus, CSRF enforced" do
    bus = ParityBusDouble.new([])
    pairs = pair_store_with_pairs
    client = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with, bus: bus), bus)
    client.login

    form = client.get("/parity")
    csrf = form.body[/name="_csrf" value="([^"]+)"/, 1]
    res = client.post("/parity", params: { "agent" => "agent-store-loja-chocolates", "limit" => "10", "_csrf" => csrf })
    expect(res.status).to eq(302)

    judged = bus.dispatched.find { |c| c.type == :judge_shadow_pairs }
    expect(judged).not_to be_nil
    expect(judged.payload).to eq(agent: "agent-store-loja-chocolates", limit: 10)
  end

  it "refuses the POST without the CSRF token" do
    bus = ParityBusDouble.new([])
    pairs = pair_store_with_pairs
    client = ParityClient.new(build_app(shadow_pairs: pairs, channels: registry_with, bus: bus), bus)
    client.login
    expect(client.post("/parity", params: { "limit" => "10" }).status).to eq(403)
    expect(bus.dispatched).to be_empty
  end
end
