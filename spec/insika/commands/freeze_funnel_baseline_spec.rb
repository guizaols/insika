# frozen_string_literal: true

require "spec_helper"

# the operator's freeze — turns the folded counts over a declared
# span into the baseline snapshot read. One command, dispatched
# from the Studio and available to any operator-grade caller. The ≥ 4-week rule
# is enforced HERE, not by convention.
RSpec.describe Insika::Commands::FreezeFunnelBaseline do
  let(:backend) { Insika::Stores::Memory.new }
  let(:funnel_store) { Insika::FunnelStore.new(store: backend) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  let(:declaration) do
    { "stages" => %w[greeted qualified cart paid],
      "advance_on" => { "qualified" => "qualified", "pix_paid" => "paid" },
      "primary" => "paid", "attribution_window" => "72h" }
  end
  let(:profiles) do
    Insika::StaticProfileSource.new(
      "store-support" => Insika::AgentProfile.build(id: "store-support", model: "m",
                                                     funnel: declaration)
    )
  end
  subject(:handler) do
    described_class.new(funnel_store: funnel_store, profiles: profiles,
                        event_stream: stream)
  end

  # 40 days (>= the 28-day rule) starting 2026-07-01.
  def seed_pair(tenant: "acme", agent: "store-support", from: "2026-07-01", days: 40)
    (0...days).each do |i|
      day = (Date.iso8601(from) + i).iso8601
      funnel_store.add(tenant: tenant, agent: agent, at: Time.iso8601("#{day}T10:00:00Z"),
                       counts: yield(day, i))
    end
  end

  def freeze(payload = {}, tenant: nil)
    handler.call(Insika::Command.build(:freeze_funnel_baseline, payload, tenant: tenant))
  end

  it "freezes a folded pair over its full span with the correct math" do
    seed_pair { |_day, i| { "greeted" => 1, "qualified" => 1, "paid" => 1 } }

    baseline = freeze({ agent: "store-support" }, tenant: "acme")
    expect(baseline["from"]).to eq("2026-07-01")
    expect(baseline["to"]).to eq("2026-08-09")
    expect(baseline["stages"]).to eq("greeted" => 40, "qualified" => 40, "paid" => 40)
    expect(baseline["primary"]).to eq("paid")
    expect(baseline["primary_count"]).to eq(40)
    expect(baseline["conversion"]).to eq(1.0)
    expect(baseline["window"]).to eq("72h") # carried from the declaration (D4)
    expect(baseline["frozen_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)

    # the Studio card reads it back verbatim
    expect(funnel_store.baseline(tenant: "acme", agent: "store-support")).to eq(baseline)
  end

  it "explicit from/to slice the span (inclusive)" do
    seed_pair { |_day, i| { "greeted" => 1, "paid" => 1 } }
    seed_pair(from: "2026-08-10", days: 20) { |_day, _i| { "greeted" => 1, "paid" => 1 } }

    baseline = freeze({ agent: "store-support", from: "2026-07-10", to: "2026-08-09" },
                      tenant: "acme")
    expect(baseline["from"]).to eq("2026-07-10")
    expect(baseline["to"]).to eq("2026-08-09")
    expect(baseline["stages"]["greeted"]).to eq(31)
    expect(baseline["primary_count"]).to eq(31)
  end

  it "missing from/to default to the pair's folded span (first/last day cell)" do
    seed_pair(days: 60) { |_day, _i| { "greeted" => 1 } }

    baseline = freeze({ agent: "store-support" }, tenant: "acme")
    expect(baseline["from"]).to eq("2026-07-01")
    expect(baseline["to"]).to eq("2026-08-29")
  end

  it "explicit from/to work on a pair with NO folded cells (no scan for the defaults)" do
    baseline = freeze({ agent: "store-support", from: "2026-07-01", to: "2026-08-10" },
                      tenant: "acme")
    expect(baseline["stages"]).to eq({})
    expect(baseline["primary_count"]).to eq(0)
    expect(baseline["conversion"]).to be_nil
  end

  it "the tenant comes from the payload or the command meta" do
    seed_pair(tenant: "zed") { |_day, _i| { "greeted" => 1 } }
    baseline = freeze({ agent: "store-support", tenant: "zed" })
    expect(funnel_store.baseline(tenant: "zed", agent: "store-support")).not_to be_nil
  end

  it "a single-tenant freeze (no tenant) lands in the 'platform' pair" do
    seed_pair(tenant: nil) { |_day, _i| { "greeted" => 1 } }
    baseline = freeze({ agent: "store-support" })
    expect(baseline["frozen_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    expect(funnel_store.baseline(tenant: "platform", agent: "store-support")).not_to be_nil
  end

  it "agent is required" do
    expect { freeze({}) }.to raise_error(Insika::ValidationError, /agent/)
  end

  it "no funnel on the agent -> ValidationError" do
    expect { freeze({ agent: "nope" }) }.to raise_error(Insika::ValidationError, /funnel/)
  end

  it "from >= to -> ValidationError" do
    seed_pair { |_day, _i| { "greeted" => 1 } }
    expect { freeze({ agent: "store-support", from: "2026-08-09", to: "2026-07-01" }, tenant: "acme") }
      .to raise_error(Insika::ValidationError, /from/)
  end

  it "a span under 28 days -> ValidationError (the 4-week rule)" do
    seed_pair(days: 10) { |_day, _i| { "greeted" => 1 } }
    expect { freeze({ agent: "store-support", from: "2026-07-01", to: "2026-07-10" }, tenant: "acme") }
      .to raise_error(Insika::ValidationError, /28 days/)
  end

  it "a zero first-stage count -> conversion nil, no crash" do
    seed_pair { |_day, _i| { "paid" => 1 } }
    baseline = freeze({ agent: "store-support" }, tenant: "acme")
    expect(baseline["stages"]).to eq("paid" => 40)
    expect(baseline["primary_count"]).to eq(40)
    expect(baseline["conversion"]).to be_nil
  end

  it "re-freeze overwrites and stamps a new frozen_at" do
    seed_pair { |_day, _i| { "greeted" => 1, "paid" => 1 } }
    allow(Time).to receive(:now).and_return(Time.iso8601("2026-08-01T00:00:00Z"))
    first = freeze({ agent: "store-support" }, tenant: "acme")
    allow(Time).to receive(:now).and_return(Time.iso8601("2026-08-02T00:00:00Z"))
    seed_pair(from: "2026-08-10", days: 10) { |_day, _i| { "greeted" => 1, "paid" => 1 } }
    second = freeze({ agent: "store-support" }, tenant: "acme")
    expect(second["frozen_at"]).not_to eq(first["frozen_at"])
    expect(second["primary_count"]).to eq(50)
    expect(funnel_store.baseline(tenant: "acme", agent: "store-support")["frozen_at"])
      .to eq(second["frozen_at"])
  end

  it "emits :funnel_baseline_frozen with COUNTS only (no content rule)" do
    seed_pair { |_day, _i| { "greeted" => 1, "paid" => 1 } }
    freeze({ agent: "store-support" }, tenant: "acme")

    ev = events.last
    expect(ev.type).to eq(:funnel_baseline_frozen)
    expect(ev.data).to eq(agent: "store-support", from: "2026-07-01",
                          to: "2026-08-09", primary: "paid",
                          primary_count: 40, conversion: 1.0)
    expect(ev.data.keys).not_to include(:stages)
  end

  it "never writes a stage name outside the declared ones" do
    seed_pair { |_day, _i| { "greeted" => 1 } }
    freeze({ agent: "store-support" }, tenant: "acme")
    baseline = funnel_store.baseline(tenant: "acme", agent: "store-support")
    expect(baseline["stages"].keys).to contain_exactly("greeted")
  end
end