# frozen_string_literal: true

require "spec_helper"

# The relay translates and authenticates, and does nothing else —
# every case here is one of those two, or the egress guard that stands between the
# engine and a URL an operator typed.
RSpec.describe Insika::Channels::Relay do
  # Duck-typed stand-in for Rack::Request: the channel only ever reads one header,
  # which is the point of not letting Rack into lib/.
  RelayReq = Struct.new(:auth) do
    def get_header(name) = name == "HTTP_AUTHORIZATION" ? auth : nil
  end

  # Records the request and answers with a scripted status.
  class RelayHttpDouble
    attr_reader :requests

    def initialize(status: 200, raise_with: nil)
      @status = status
      @raise_with = raise_with
      @requests = []
    end

    def request(**kwargs)
      @requests << kwargs
      raise @raise_with if @raise_with

      { status: @status, body: "" }
    end
  end

  def relay(**over)
    described_class.new(**{ inbound_token: "in-tok", deliver_url: "https://8.8.8.8/hook",
                            deliver_token: "out-tok", http: http }.merge(over))
  end

  let(:http) { RelayHttpDouble.new }

  describe "authenticate" do
    it "accepts the configured bearer" do
      expect(relay.authenticate(RelayReq.new("Bearer in-tok"))).to eq(:ok)
    end

    it "refuses a wrong or missing bearer" do
      expect(relay.authenticate(RelayReq.new("Bearer nope"))).to eq(:unauthorized)
      expect(relay.authenticate(RelayReq.new(nil))).to eq(:unauthorized)
      expect(relay.authenticate(RelayReq.new("Basic in-tok"))).to eq(:unauthorized)
    end

    # Fail-closed by construction: an unconfigured public inbound route with an LLM
    # behind it would be a money faucet, so "no credential" is never "no check".
    it "is :disabled — never open — when no token is configured" do
      expect(relay(inbound_token: "").authenticate(RelayReq.new("Bearer anything"))).to eq(:disabled)
    end
  end

  # The token is the SWITCH, not just a credential: there is no configuration that
  # produces a mounted relay without a secret in front of it.
  describe ".from_env" do
    it "builds nothing without a token, whatever else is set" do
      expect(described_class.from_env({ "INSIKA_RELAY_DELIVER_URL" => "https://8.8.8.8/h" })).to be_nil
      expect(described_class.from_env({})).to be_nil
    end

    it "builds the channel from the three vars" do
      channel = described_class.from_env({ "INSIKA_RELAY_TOKEN" => "in-tok",
                                           "INSIKA_RELAY_DELIVER_URL" => "https://8.8.8.8/h",
                                           "INSIKA_RELAY_DELIVER_TOKEN" => "out-tok" }, http: http)
      expect(channel.id).to eq("relay")
      expect(channel.authenticate(RelayReq.new("Bearer in-tok"))).to eq(:ok)

      channel.deliver({}, to: "1")
      expect(http.requests.first[:headers]["authorization"]).to eq("Bearer out-tok")
    end

    it "still honors the deprecated HARNESS_ alias, like every other engine key" do
      expect(described_class.from_env({ "HARNESS_RELAY_TOKEN" => "t" })).not_to be_nil
    end

    it "reads INSIKA_RELAY_SHADOW as the shadow switch" do
      env = { "INSIKA_RELAY_TOKEN" => "t", "INSIKA_RELAY_SHADOW" => "1" }
      expect(described_class.from_env(env)).to be_shadow
      expect(described_class.from_env({ "INSIKA_RELAY_TOKEN" => "t" })).not_to be_shadow
      expect(described_class.from_env({ "INSIKA_RELAY_TOKEN" => "t", "INSIKA_RELAY_SHADOW" => "0" })).not_to be_shadow
    end
  end

  describe "shadow mode " do
    it "is off by default — every existing caller keeps working" do
      expect(relay.shadow?).to be(false)
    end

    it "refuses to deliver, loudly and immediately — the turn's answer never reaches the customer" do
      expect do
        relay(shadow: true).deliver({ "content" => "oi" }, to: "5511999998888")
      end.to raise_error(Insika::DeliveryError, /shadow mode/)
      expect(http.requests).to be_empty # and nothing was POSTed
    end

    it "requires event_id in shadow — the correlation key both halves are built from" do
      shadow = relay(shadow: true)
      expect { shadow.parse(nil, body: { "agent" => "a", "external_id" => "e", "message" => "oi" }) }
        .to raise_error(Insika::ValidationError, /event_id is required in shadow mode/)
      parsed = shadow.parse(nil, body: { "agent" => "a", "external_id" => "e", "message" => "oi", "event_id" => "wamid.1" })
      expect(parsed[:event_id]).to eq("wamid.1")
    end

    it "still accepts a missing event_id outside shadow (the dedup key stays optional)" do
      expect(relay.parse(nil, body: { "agent" => "a", "external_id" => "e", "message" => "oi" })[:event_id]).to be_nil
    end

    it "passes the mirror's own reply through parse (Shape 1, optional outside shadow too)" do
      body = { "agent" => "a", "external_id" => "e", "message" => "oi",
               "event_id" => "wamid.1", "incumbent_reply" => "me passa o número?" }
      expect(relay(shadow: true).parse(nil, body: body)[:incumbent_reply]).to eq("me passa o número?")
      expect(relay.parse(nil, body: body)[:incumbent_reply]).to eq("me passa o número?")
    end

    describe "parse_shadow_reply (the follow-up, Shape 2)" do
      let(:body) { { "external_id" => "5511999998888", "event_id" => "wamid.1",
                     "reply" => "me passa o número?" } }

      it "parses the three required fields and the optional at" do
        parsed = relay(shadow: true).parse_shadow_reply(nil, body: body)
        expect(parsed).to eq({ external_id: "5511999998888", event_id: "wamid.1",
                               reply: "me passa o número?", at: nil })
      end

      it "refuses a missing field" do
        expect { relay.parse_shadow_reply(nil, body: body.merge("event_id" => nil)) }
          .to raise_error(Insika::ValidationError, /event_id/)
        expect { relay.parse_shadow_reply(nil, body: body.merge("reply" => "  ")) }
          .to raise_error(Insika::ValidationError, /reply/)
      end

      it "refuses a non-ISO at" do
        expect { relay.parse_shadow_reply(nil, body: body.merge("at" => "ontem")) }
          .to raise_error(Insika::ValidationError, /ISO8601/)
      end
    end
  end

  describe "parse" do
    it "normalizes the consumer's envelope" do
      out = relay.parse(nil, body: { "agent" => "support", "external_id" => "5511999998888",
                                     "message" => "queria saber do pedido", "event_id" => "wamid.1",
                                     "vars" => { "store" => "demo-store" } })
      expect(out).to eq(agent: "support", external_id: "5511999998888",
                        message: "queria saber do pedido", event_id: "wamid.1",
                        incumbent_reply: nil, vars: { "store" => "demo-store" })
    end

    it "treats event_id and vars as optional" do
      out = relay.parse(nil, body: { "agent" => "support", "external_id" => "551", "message" => "oi" })
      expect(out[:event_id]).to be_nil
      expect(out[:vars]).to eq({})
    end

    it "refuses a request missing any of the three required fields" do
      base = { "agent" => "support", "external_id" => "551", "message" => "oi" }
      %w[agent external_id message].each do |field|
        expect { relay.parse(nil, body: base.merge(field => "")) }
          .to raise_error(Insika::ValidationError, /#{field}/)
      end
    end

    it "refuses a whitespace-only message (nothing to answer)" do
      expect { relay.parse(nil, body: { "agent" => "a", "external_id" => "1", "message" => "   " }) }
        .to raise_error(Insika::ValidationError)
    end
  end

  # the engine namespaces the platform's key so a Slack channel id and a phone
  # number can never collide, and an id minted for one channel cannot read another's.
  describe "session correlation" do
    it "namespaces the external id and reads it back" do
      expect(relay.session_id_for("5511999998888")).to eq("relay:5511999998888")
      expect(relay.external_id_from("relay:5511999998888")).to eq("5511999998888")
      expect(relay.external_id_from("web:abc")).to be_nil
    end
  end

  describe "delivery policy " do
    it "is :at_end by default — every existing caller keeps working, one POST" do
      expect(relay.delivery).to eq(:at_end)
      expect(relay.progressive?).to be(false)
    end

    it "a relay built with delivery: :progressive answers progressive?" do
      expect(relay(delivery: :progressive).progressive?).to be(true)
    end

    it "from_env reads INSIKA_RELAY_DELIVERY as the switch, unset = :at_end" do
      env = { "INSIKA_RELAY_TOKEN" => "t", "INSIKA_RELAY_DELIVER_URL" => "https://8.8.8.8/h" }
      expect(described_class.from_env(env)).not_to be_progressive
      expect(described_class.from_env(env.merge("INSIKA_RELAY_DELIVERY" => "progressive"))).to be_progressive
      expect(described_class.from_env(env.merge("INSIKA_RELAY_DELIVERY" => "at_end"))).not_to be_progressive
    end

    it "refuses an unknown policy at construction — a typo dies at boot, not per turn" do
      expect { relay(delivery: "banana") }.to raise_error(Insika::ConfigError, /unknown relay delivery/)
      expect { described_class.policy!("banana") }.to raise_error(Insika::ConfigError, /at_end, progressive/)
    end

    it "deliver still POSTs ONE payload — the policy never turns this class into a splitter" do
      relay(delivery: :progressive).deliver({ "content" => "ola" }, to: "5511999998888")
      expect(http.requests.size).to eq(1)
      expect(JSON.parse(http.requests.first[:body])).to eq("content" => "ola", "external_id" => "5511999998888")
    end
  end

  describe "deliver" do
    it "POSTs the reply with the recipient, the bearer and the idempotency key" do
      status = relay.deliver({ "content" => "seu pedido saiu" }, to: "5511999998888", delivery_id: "ob-1")

      expect(status).to eq(200)
      req = http.requests.first
      expect(req[:url]).to eq("https://8.8.8.8/hook")
      expect(req[:headers]["authorization"]).to eq("Bearer out-tok")
      expect(req[:headers]["x-insika-delivery"]).to eq("ob-1")
      expect(JSON.parse(req[:body])).to eq("content" => "seu pedido saiu", "external_id" => "5511999998888")
    end

    it "reports the status verbatim — deciding what 2xx means is the dispatcher's job" do
      expect(relay(http: RelayHttpDouble.new(status: 503)).deliver({}, to: "1")).to eq(503)
    end

    it "omits the bearer when the consumer authenticates us another way" do
      relay(deliver_token: nil).deliver({}, to: "1")
      expect(http.requests.first[:headers]).not_to have_key("authorization")
    end

    it "raises DeliveryError when no callback is configured" do
      expect { relay(deliver_url: "").deliver({}, to: "1") }
        .to raise_error(Insika::DeliveryError, /not configured/)
    end

    it "turns a transport failure into a DeliveryError, never a turn failure" do
      failing = relay(http: RelayHttpDouble.new(raise_with: Errno::ECONNREFUSED.new("hook")))
      expect { failing.deliver({}, to: "1") }.to raise_error(Insika::DeliveryError, /ECONNREFUSED/)
    end

    # The guard runs on EVERY call, not once at boot: a hostname that answered a
    # public address yesterday can answer 169.254.169.254 today, and this POST
    # carries the customer's conversation.
    describe "the egress guard" do
      it "refuses plain http unless the operator opted in" do
        expect { relay(deliver_url: "http://8.8.8.8/hook").deliver({}, to: "1") }
          .to raise_error(Insika::DeliveryError, /egress blocked/)
      end

      it "refuses a loopback callback unless the operator opted in" do
        expect { relay(deliver_url: "https://127.0.0.1/hook").deliver({}, to: "1") }
          .to raise_error(Insika::DeliveryError, /egress blocked/)
      end

      it "allows the local consumer once both flags are on (the dev/pilot case)" do
        local = relay(deliver_url: "http://127.0.0.1:3000/hook", allow_http: true, allow_private: true)
        expect(local.deliver({}, to: "1")).to eq(200)
      end

      it "refuses a URL that is not one" do
        expect { relay(deliver_url: "not a url").deliver({}, to: "1") }
          .to raise_error(Insika::DeliveryError, /egress blocked/)
      end
    end
  end
end
