# frozen_string_literal: true

require "spec_helper"

# the widget is the first PUBLIC channel, so the cases that matter
# are the ones where being wrong costs money (an open route with an LLM behind it)
# or costs a customer their privacy (a session id someone else can use).
RSpec.describe Insika::Channels::Web do
  ORIGIN = "https://shop.example"

  def channel(**over)
    described_class.new(**{ origins: [ORIGIN], agents: %w[support],
                            chat_rate_limit: ->(_agent) { 6 } }.merge(over))
  end

  # No Rack here on purpose: `authenticate` takes a verdict-shaped decision and the
  # channel never learns what HTTP is, so a request is anything with `get_header`.
  Req = Struct.new(:headers) do
    def get_header(name) = headers[name]
  end

  def request(origin: nil) = Req.new(origin ? { "HTTP_ORIGIN" => origin } : {})

  describe "from_env — both allowlists are the switch" do
    it "builds when the operator declared where it embeds and what it may address" do
      web = described_class.from_env({ "INSIKA_WIDGET_ORIGINS" => "#{ORIGIN}, https://b.example",
                                       "INSIKA_WIDGET_AGENTS" => "support,sales" },
                                     chat_rate_limit: ->(_a) { 6 })
      expect(web.id).to eq("web")
      expect(web.authenticate(request(origin: "https://b.example"))).to eq(:ok)
      expect(web.parse(nil, body: { "agent" => "sales", "session_id" => "web:1", "message" => "oi" })[:agent])
        .to eq("sales")
    end

    it "is nil with either half missing — half a switch is not a switch" do
      expect(described_class.from_env({ "INSIKA_WIDGET_ORIGINS" => ORIGIN })).to be_nil
      expect(described_class.from_env({ "INSIKA_WIDGET_AGENTS" => "support" })).to be_nil
      expect(described_class.from_env({})).to be_nil
    end
  end

  # "a public channel with an LLM behind it is a money faucet". The limit is a
  # requirement, not a suggestion, and the fail-closed direction is the whole point.
  describe "the mandatory rate limit" do
    it "is :ok once every published agent has a positive limit" do
      expect(channel.authenticate(request)).to eq(:ok)
    end

    it "is :disabled with no probe wired at all" do
      expect(channel(chat_rate_limit: nil).authenticate(request)).to eq(:disabled)
    end

    it "is :disabled when the limit resolves to nothing" do
      expect(channel(chat_rate_limit: ->(_a) { nil }).authenticate(request)).to eq(:disabled)
    end

    # A per-agent 0 explicitly disables a platform default (EdgeLimiter's rule), so
    # it is an absent ceiling here too — not a ceiling of zero.
    it "is :disabled when the limit is 0" do
      expect(channel(chat_rate_limit: ->(_a) { 0 }).authenticate(request)).to eq(:disabled)
    end

    it "is :disabled when only SOME published agents have one" do
      web = channel(agents: %w[support sales], chat_rate_limit: ->(a) { a == "support" ? 6 : nil })
      expect(web.authenticate(request)).to eq(:disabled)
    end

    # Resolved per check, not at boot: an operator who removes the limit tomorrow
    # closes the widget instead of leaving it open because it was right once.
    it "closes when the limit is removed while the process runs" do
      limit = 6
      web = channel(chat_rate_limit: ->(_a) { limit })
      expect(web.authenticate(request)).to eq(:ok)
      limit = nil
      expect(web.authenticate(request)).to eq(:disabled)
    end
  end

  describe "limit_resolver — asked the way EdgeLimiter asks it" do
    Prof = Struct.new(:limits)

    def profiles(limits) = Class.new { define_method(:fetch) { |_id| limits.nil? ? nil : Prof.new(limits) } }.new
    def settings(hash) = Class.new { define_method(:get) { hash } }.new

    it "prefers the per-agent override over the platform default" do
      resolve = described_class.limit_resolver(profiles: profiles({ chat_rate_limit: 3 }),
                                               settings_store: settings({ "edge" => { "chat_rate_limit" => 60 } }))
      expect(resolve.call("support")).to eq(3)
    end

    it "falls back to the platform default" do
      resolve = described_class.limit_resolver(profiles: profiles({}),
                                               settings_store: settings({ "edge" => { "chat_rate_limit" => 60 } }))
      expect(resolve.call("support")).to eq(60)
    end

    # Present-but-nil reads as OFF for that agent, not "inherit" — same rule the
    # limiter applies, so the gate cannot disagree with the enforcement.
    it "reads a per-agent nil as off, not as inherit" do
      resolve = described_class.limit_resolver(profiles: profiles({ chat_rate_limit: nil }),
                                               settings_store: settings({ "edge" => { "chat_rate_limit" => 60 } }))
      expect(resolve.call("support")).to be_nil
    end

    it "is nil for an unknown agent with no platform default" do
      resolve = described_class.limit_resolver(profiles: profiles(nil), settings_store: settings({}))
      expect(resolve.call("ghost")).to be_nil
    end
  end

  # CORS is a browser courtesy, not a security control. Refusing a request
  # with no Origin would be theatre (curl sets any origin it likes) — and the rate
  # limit above is what actually defends the route.
  describe "the origin allowlist" do
    it "accepts an allowlisted origin" do
      expect(channel.authenticate(request(origin: ORIGIN))).to eq(:ok)
    end

    it "401s an origin nobody allowlisted" do
      expect(channel.authenticate(request(origin: "https://evil.example"))).to eq(:unauthorized)
    end

    it "401s every browser when the list is empty — there is no allow-all value" do
      expect(channel(origins: []).authenticate(request(origin: ORIGIN))).to eq(:unauthorized)
    end

    it "does not match a prefix or a subdomain" do
      web = channel(origins: ["https://shop.example"])
      expect(web.authenticate(request(origin: "https://shop.example.evil.com"))).to eq(:unauthorized)
      expect(web.authenticate(request(origin: "https://a.shop.example"))).to eq(:unauthorized)
    end

    it "returns headers only for an allowlisted origin" do
      expect(channel.cors_headers(ORIGIN)).to include("access-control-allow-origin" => ORIGIN)
      expect(channel.cors_headers("https://evil.example")).to eq("vary" => "origin")
      expect(channel.cors_headers(nil)).to eq("vary" => "origin")
    end
  end

  describe "parse" do
    def body(**over)
      { "agent" => "support", "session_id" => "web:abc", "message" => "oi" }.merge(over.transform_keys(&:to_s))
    end

    it "normalizes the three fields it needs" do
      expect(channel.parse(nil, body: body)).to eq(agent: "support", session_id: "web:abc", message: "oi")
    end

    # A refusal, not a grant (R2): the profile still decides what `support` may do.
    it "refuses an agent the operator did not publish to the widget" do
      expect { channel.parse(nil, body: body(agent: "internal-admin")) }
        .to raise_error(Insika::ValidationError, /not published/)
    end

    %w[agent session_id message].each do |field|
      it "refuses a missing #{field}" do
        expect { channel.parse(nil, body: body(field => "")) }
          .to raise_error(Insika::ValidationError, /#{field}/)
      end
    end

    it "refuses a whitespace-only message" do
      expect { channel.parse(nil, body: body(message: "   ")) }.to raise_error(Insika::ValidationError)
    end

    it "tolerates a body that is not a hash" do
      expect { channel.parse(nil, body: "nope") }.to raise_error(Insika::ValidationError)
    end
  end

  #'s hard rule: the ENGINE issues the id. A visitor-proposed id on an
  # anonymous endpoint is session hijacking by enumeration.
  describe "mint_session_id" do
    it "is namespaced and unguessable" do
      a = channel.mint_session_id
      b = channel.mint_session_id
      expect(a).to start_with("web:")
      expect(a.delete_prefix("web:").length).to be >= 32
      expect(a).not_to eq(b)
    end
  end

  describe "frame_for" do
    def ev(type, data = {}) = Insika::Event.new(type: type, data: data, meta: { task_id: "t" })

    it "maps the four frames the widget protocol has" do
      expect(channel.frame_for(ev(:content, { delta: "Oi" }))).to eq(%(event: delta\ndata: {"delta":"Oi"}\n\n))
      expect(channel.frame_for(ev(:tool_call, { name: "search" }))).to eq(%(event: working\ndata: {"name":"search"}\n\n))
      expect(channel.frame_for(ev(:task_completed))).to eq(%(event: done\ndata: {}\n\n))
      expect(channel.frame_for(ev(:task_failed, { message: "boom" })))
        .to eq(%(event: error\ndata: {"message":"boom"}\n\n))
    end

    it "reports a cancelled turn as an error rather than a clean finish" do
      expect(channel.frame_for(ev(:task_cancelled))).to include("event: error")
    end

    # `:content` is the ANSWER. The narration on the way there is internal, and
    # a widget that rendered it would show the customer the engine thinking aloud.
    it "publishes neither the model's reasoning nor its intermediate prose" do
      expect(channel.frame_for(ev(:thinking, { delta: "hmm", public: true }))).to be_nil
      expect(channel.frame_for(ev(:intermediate, { delta: "let me check", public: true }))).to be_nil
      expect(channel.frame_for(ev(:task_started))).to be_nil
    end
  end

  describe "asset" do
    it "serves the widget with an etag and a cache policy" do
      asset = channel.asset("widget.js")
      expect(asset[:content_type]).to start_with("application/javascript")
      expect(asset[:body]).to include("insika")
      expect(asset[:etag]).to match(/\A"[0-9a-f]{16}"\z/)
      expect(asset[:cache_control]).to include("max-age")
    end

    # A closed map, not a directory: `asset/:f` takes a name off the URL, and
    # anything that resolves a path from user input is a traversal waiting to happen.
    it "is a closed map — no traversal, no unknown names" do
      expect(channel.asset("../../../../etc/passwd")).to be_nil
      expect(channel.asset("widget.js/../secrets")).to be_nil
      expect(channel.asset("nope.js")).to be_nil
    end
  end

  # Shape A: the reply comes back on the request's own stream, so there is nothing
  # for the outbox to hold. `ChannelRegistry#deliverable?` reads exactly this.
  it "has no deliver — nothing is ever written to the outbox for it" do
    expect(channel).not_to respond_to(:deliver)
    registry = Insika::ChannelRegistry.new.tap { |r| r.register("web", channel) }
    expect(registry.deliverable?("web")).to be(false)
  end
end
