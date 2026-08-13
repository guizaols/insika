# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../lib/insika/server/app"
require_relative "../../support/server_doubles"

# WS7: business outcomes over real traffic — POST /v1/outcomes records a
# conversation's outcome (operator or integration), GET /v1/outcomes serves the
# Studio scorecard (last outcome per agent + per-period series), and the
# records are tenant-isolated (WS1).
RSpec.describe Insika::Server::App do
  let(:backend) { Insika::Stores::Memory.new }
  let(:event_stream) { Insika::EventStream.new }

  # A real CommandBus with :record_outcome wired to a real OutcomeStore — POST
  # /v1/outcomes is end-to-end; GET reads the same store directly.
  def build_app(store: backend, tenancy: "single_tenant", token: nil)
    outcome_store = Insika::OutcomeStore.new(store: store)
    bus = Insika::CommandBus.new
    bus.register(:record_outcome, Insika::Commands::RecordOutcome.new(
                                    outcome_store: outcome_store, event_stream: event_stream
                                  ))
    described_class.new(
      command_bus: bus, event_stream: event_stream,
      session_store: ServerStoreDouble.new(nil), task_store: ServerStoreDouble.new(nil),
      outcome_store: outcome_store, token_store: token,
      config: { sync_timeout: 0.05, gateway_token: "op-sekret", tenancy: tenancy }
    )
  end

  def call(app, method, path, body: nil, auth: nil)
    opts = { method: method }
    opts[:input] = body if body
    env = Rack::MockRequest.env_for(path, opts)
    env["HTTP_AUTHORIZATION"] = "Bearer #{auth}" if auth
    app.call(env)
  end

  def json(resp) = JSON.parse(resp.join)

  it "POST /v1/outcomes records the outcome and answers 201 with it" do
    store = Insika::OutcomeStore.new(store: backend)
    app = build_app(store: backend)

    status, _h, resp = call(app, "POST", "/v1/outcomes",
                            body: JSON.generate(agent: "bia", session_id: "s-9",
                                                outcome: "conversion", value: 129.9),
                            auth: "op-sekret")

    expect(status).to eq(201)
    body = json(resp)
    expect(body["outcome"]).to include("agent" => "bia", "outcome" => "conversion",
                                       "value" => 129.9, "session_id" => "s-9")
    expect(store.all.size).to eq(1)
    expect(store.all.first.agent).to eq("bia")
  end

  it "outcome and agent are required (422); value must be a number" do
    app = build_app
    expect(call(app, "POST", "/v1/outcomes", body: JSON.generate(outcome: "x"),
                auth: "op-sekret")[0]).to eq(422)
    expect(call(app, "POST", "/v1/outcomes", body: JSON.generate(agent: "bia"),
                auth: "op-sekret")[0]).to eq(422)
    expect(call(app, "POST", "/v1/outcomes",
                body: JSON.generate(agent: "bia", outcome: "x", value: "129"),
                auth: "op-sekret")[0]).to eq(422)
  end

  it "GET /v1/outcomes serves the Studio scorecard: latest per agent + per-day series" do
    store = Insika::OutcomeStore.new(store: backend)
    app = build_app(store: backend)
    2.times do |i|
      call(app, "POST", "/v1/outcomes",
           body: JSON.generate(agent: "bia", outcome: "conversion", value: 100),
           auth: "op-sekret")
      call(app, "POST", "/v1/outcomes",
           body: JSON.generate(agent: "ana", outcome: "deflected"), auth: "op-sekret")
    end

    status, _h, resp = call(app, "GET", "/v1/outcomes", auth: "op-sekret")
    expect(status).to eq(200)
    body = json(resp)
    expect(body["latest"]["bia"]).to include("outcome" => "conversion", "value" => 100.0)
    expect(body["latest"]["ana"]).to include("outcome" => "deflected")
    date = body["series"].keys.first
    expect(body["series"][date]["conversion"]).to include("count" => 2, "value" => 200.0)
    expect(body["series"][date]["deflected"]).to include("count" => 2)

    # ?agent= narrows both aggregates
    body2 = json(call(app, "GET", "/v1/outcomes?agent=bia", auth: "op-sekret")[2])
    expect(body2["latest"].keys).to eq(["bia"])
  end

  describe "tenant isolation (WS1)" do
    let(:token_store) { Insika::TokenStore.new(store: backend) }
    let!(:tenant_a) { token_store.issue(tenant_id: "loja-a") }
    let!(:tenant_b) { token_store.issue(tenant_id: "loja-b") }

    it "a tenant's outcome lands under its tenant and is invisible to the other" do
      app = build_app(tenancy: "multi_tenant", token: token_store)

      status, _h, resp = call(app, "POST", "/v1/outcomes",
                              body: JSON.generate(agent: "bia", outcome: "conversion"),
                              auth: tenant_a.token)
      expect(status).to eq(201)

      # tenant A sees its own outcome
      own = json(call(app, "GET", "/v1/outcomes", auth: tenant_a.token)[2])
      expect(own["latest"]["bia"]).to include("outcome" => "conversion")

      # tenant B sees nothing — the isolation is the key itself
      other = json(call(app, "GET", "/v1/outcomes", auth: tenant_b.token)[2])
      expect(other["latest"]).to eq({})

      # and the underlying cell carries the tenant (the record is stamped)
      record = Insika::OutcomeStore.new(store: backend).all.first
      expect(record.tenant).to eq("loja-a")
    end
  end
end