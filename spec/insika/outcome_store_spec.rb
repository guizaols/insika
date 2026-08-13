# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::OutcomeStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:now) { Time.utc(2026, 8, 12, 12, 0, 0) }

  it "creates a record and lists it newest-first" do
    a = store.create(tenant: "loja-a", agent: "bia", session_id: "s-1", outcome: "conversion",
                     value: 129.9, at: now)
    b = store.create(tenant: "loja-a", agent: "bia", outcome: "deflected", at: now + 3600)

    expect(store.all.first).to eq(b)
    expect(store.all.last).to eq(a)
    expect(a.agent).to eq("bia")
    expect(a.value).to eq(129.9)
  end

  it "defaults value to 0.0 and at to now" do
    rec = store.create(tenant: nil, agent: "ana", outcome: "deflected")
    expect(rec.value).to eq(0.0)
    expect(rec.at).not_to be_nil
  end

  it "latest_per_agent is the LAST outcome per agent (the state card)" do
    store.create(tenant: nil, agent: "bia", outcome: "conversion", at: now)
    store.create(tenant: nil, agent: "bia", outcome: "escalation", at: now + 60)
    store.create(tenant: nil, agent: "ana", outcome: "deflected", at: now)

    expect(store.latest_per_agent["bia"]).to include(outcome: "escalation")
    expect(store.latest_per_agent["ana"]).to include(outcome: "deflected")
  end

  it "all/tenant narrows to one tenant's records (WS1)" do
    store.create(tenant: "loja-a", agent: "bia", outcome: "conversion")
    store.create(tenant: "loja-b", agent: "bia", outcome: "escalation")

    expect(store.all(tenant: "loja-a").size).to eq(1)
    expect(store.all(tenant: "loja-a").first.agent).to eq("bia")
    expect(store.latest_per_agent(tenant: "loja-b")["bia"]).to include(outcome: "escalation")
    # a tenant ignoring its own tenant sees nothing of the other's
    expect(store.all(tenant: "loja-a").map(&:outcome)).to eq(%w[conversion])
  end

  it "series buckets by period: daily by default, monthly by YYYY-MM" do
    store.create(tenant: nil, agent: "bia", outcome: "conversion", value: 100, at: Time.utc(2026, 8, 12, 9))
    store.create(tenant: nil, agent: "bia", outcome: "conversion", value: 50, at: Time.utc(2026, 8, 13, 9))
    store.create(tenant: nil, agent: "ana", outcome: "deflected", at: Time.utc(2026, 9, 1))

    daily = store.series
    expect(daily["2026-08-12"]["conversion"]).to eq(count: 1, value: 100.0)
    expect(daily["2026-08-13"]["conversion"]).to eq(count: 1, value: 50.0)

    monthly = store.series(period: :month)
    expect(monthly.keys.sort).to eq(%w[2026-08 2026-09])
    expect(monthly["2026-08"]["conversion"]).to eq(count: 2, value: 150.0)
  end

  it "works on the SQLite backend (the durable production path)" do
    sqlite = Insika::Stores::SQLite.new(path: ":memory:")
    durable = described_class.new(store: sqlite)
    durable.create(tenant: "t", agent: "bia", outcome: "conversion", value: 10)
    expect(durable.latest_per_agent["bia"]).to include(outcome: "conversion")
  ensure
    sqlite&.close
  end
end