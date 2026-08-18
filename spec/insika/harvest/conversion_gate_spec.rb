# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# C8 — the second gate (D6): the store's target METRIC RATE over the
# criterion's window, compared to the frozen baseline's rate. The ruler is a
# rate, never a total — the frozen span (≥ 28 days) and the window (72 h)
# have different scales, and comparing raw counts would flag a store that
# tripled its traffic as "worse". Outcome is EVIDENCE — the only verdict this
# object can produce is "the store is measurably worse than the accepted
# state" and "there is nothing to compare against". It REFUSES on missing
# data, never passes (the P18 lesson applied to the second ruler).
RSpec.describe Insika::Harvest::ConversionGate do
  subject(:gate) { described_class.new(funnel_store: funnel, criterion: criterion) }

  let(:tmp) { Dir.mktmpdir("harvest-cg") }
  after { FileUtils.remove_entry(tmp) }

  def write_criterion(body)
    path = File.join(tmp, "CRITERION.md")
    File.write(path, body)
    Insika::Harvest::Criterion.load(path)
  end

  let(:criterion) do
    write_criterion(<<~MD)
      # criterion

      ```yaml
      version: 1
      metric: paid
      window: 72h
      threshold: 0.05
      min_span: 28d
      ```
    MD
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:funnel) { Insika::FunnelStore.new(store: backend) }

  def seed_days(counts)
    funnel.add(tenant: nil, agent: "store-support", at: Time.now.utc - 86_400, counts: counts)
    funnel.add(tenant: nil, agent: "store-support", at: Time.now.utc, counts: counts)
  end

  def freeze_baseline(primary_count:, primary: "paid", stage_counts: nil)
    from = (Time.now.utc - 30 * 86_400).strftime("%Y-%m-%d")
    to = Time.now.utc.strftime("%Y-%m-%d")
    counts = stage_counts || { "greeted" => 1000, "paid" => primary_count }
    denom = counts[counts.keys.first].to_f
    {
      "from" => from, "to" => to,
      "stages" => counts,
      "primary" => primary, "primary_count" => counts[primary].to_i,
      "conversion" => denom.zero? ? nil : (counts[primary].to_f / denom),
      "window" => "72h", "frozen_at" => Time.now.utc.iso8601
    }
  end

  describe "E3's conversion half" do
    it "compares RATES, not totals — the reviewer's proof: 280 paid over 28 days vs 45 over 3 days (a store that improved) PASSES" do
      # baseline: 280 paid / 2800 greeted over the frozen 28-day span (rate 0.1)
      funnel.set_baseline(tenant: nil, agent: "store-support",
                          record: freeze_baseline(primary_count: 280,
                                                  stage_counts: { "greeted" => 2800, "paid" => 280 }))
      # window: 44 paid / 450 greeted over the 72h window — a HIGHER daily rate
      # (the raw total is far below 280, yet the store is healthier per unit)
      seed_days("greeted" => 225, "paid" => 22) # 44/450 = 0.0978, within the 5% bar
      result = gate.call(tenant: nil, agent: "store-support")
      expect(result.passed).to be(true)
      expect(result.reason).to be_nil
    end

    it "a current rate 2% below the baseline passes with threshold 0.05 (not worse)" do
      funnel.set_baseline(tenant: nil, agent: "store-support", record: freeze_baseline(primary_count: 100))
      seed_days("greeted" => 1000, "paid" => 98) # 196/2000 = 0.098 vs 0.1
      result = gate.call(tenant: nil, agent: "store-support")
      expect(result.passed).to be(true)
      expect(result.current).to be_within(0.0001).of(0.098)
      expect(result.baseline).to eq(0.1)
      expect(result.threshold).to eq(0.05)
      expect(result.reason).to be_nil
    end

    it "a current rate 8% below the baseline is refused WITH the numbers" do
      funnel.set_baseline(tenant: nil, agent: "store-support", record: freeze_baseline(primary_count: 100))
      seed_days("greeted" => 1000, "paid" => 92) # 184/2000 = 0.092
      result = gate.call(tenant: nil, agent: "store-support")
      expect(result.passed).to be(false)
      expect(result.reason).to eq(:conversion_down)
      expect(result.current).to be_within(0.0001).of(0.092)
      expect(result.baseline).to eq(0.1)
    end

    it "the threshold boundary is exact: 5.0% below passes, just under refuses" do
      funnel.set_baseline(tenant: nil, agent: "store-support", record: freeze_baseline(primary_count: 100))
      # 190/2000 = 0.095 = exactly the boundary (>= 0.1 * 0.95)
      seed_days("greeted" => 1000, "paid" => 95)
      expect(gate.call(tenant: nil, agent: "store-support").passed).to be(true)

      funnel.delete_days(tenant: nil, agent: "store-support")
      seed_days("greeted" => 1000, "paid" => 94) # 188/2000 = 0.094 = 6% below
      expect(gate.call(tenant: nil, agent: "store-support").passed).to be(false)
    end
  end

  describe "refuse-with-a-named-reason, never pass, on missing data (D6)" do
    it ":no_criterion — the gate refuses without the frozen file" do
      g = described_class.new(funnel_store: funnel, criterion: nil)
      expect(g.call(tenant: nil, agent: "a").reason).to eq(:no_criterion)
      expect(g.call(tenant: nil, agent: "a").passed).to be(false)
    end

    it ":no_funnel — a bare install without a ruler cannot promote on outcome" do
      g = described_class.new(funnel_store: nil, criterion: criterion)
      expect(g.call(tenant: nil, agent: "a").reason).to eq(:no_funnel)
    end

    it ":no_frozen_baseline — never frozen, never compared" do
      seed_days("paid" => 5)
      expect(gate.call(tenant: nil, agent: "store-support").reason).to eq(:no_frozen_baseline)
    end

    it ":metric_mismatch — the criterion names a stage the frozen baseline does not declare" do
      funnel.set_baseline(tenant: nil, agent: "store-support",
                          record: freeze_baseline(primary_count: 50, primary: "cart"))
      seed_days("cart" => 10)
      result = gate.call(tenant: nil, agent: "store-support")
      expect(result.reason).to eq(:metric_mismatch)
      expect(result.to_h["reason"]).to eq("metric_mismatch")
    end

    it ":baseline_span_short — the frozen baseline's span must cover the criterion's min_span" do
      funnel.set_baseline(tenant: nil, agent: "store-support",
                          record: freeze_baseline(primary_count: 100).merge(
                            "from" => (Time.now.utc - 3 * 86_400).strftime("%Y-%m-%d")
                          ))
      seed_days("greeted" => 1000, "paid" => 100)
      expect(gate.call(tenant: nil, agent: "store-support").reason).to eq(:baseline_span_short)
    end

    it ":no_baseline_rate — a baseline with no first-stage events cannot be the ruler" do
      funnel.set_baseline(tenant: nil, agent: "store-support",
                          record: freeze_baseline(primary_count: 0,
                                                  stage_counts: { "paid" => 0 }))
      seed_days("greeted" => 1000, "paid" => 100)
      expect(gate.call(tenant: nil, agent: "store-support").reason).to eq(:no_baseline_rate)
    end

    it ":no_fold — no day cells over the criterion's window" do
      funnel.set_baseline(tenant: nil, agent: "store-support", record: freeze_baseline(primary_count: 100))
      expect(gate.call(tenant: nil, agent: "store-support").reason).to eq(:no_fold)
    end
  end

  describe "the Result record" do
    it "to_h is the candidate's conversion_gate record (the ruler's rates)" do
      funnel.set_baseline(tenant: nil, agent: "store-support", record: freeze_baseline(primary_count: 100))
      seed_days("greeted" => 1000, "paid" => 95)
      h = gate.call(tenant: nil, agent: "store-support").to_h
      expect(h).to include("passed" => true, "metric" => "paid", "window" => "72h",
                           "current" => 0.095, "baseline" => 0.1, "threshold" => 0.05,
                           "snapshot_ref" => a_string_matching(/\Afunnel:/))
    end
  end
end