# frozen_string_literal: true

require "spec_helper"
require "json"

# C6 — the mechanical fold. Pure over pairs + criterion + an injected `now`, so
# two people reading the same pairs get the same answer (E3). Every terminal
# state has its own case; the fixture is the E3 experiment itself.
RSpec.describe Insika::Parity::Verdict do
  CRITERION = Insika::Parity::Criterion.load(File.expand_path("../../fixtures/parity/criterion.md", __dir__))

  FIXED_NOW = Time.utc(2026, 8, 15, 12, 0, 0)

  ParityPair = Data.define(
    :id, :channel, :agent, :session_id, :task_id, :event_id,
    :inbound, :incumbent_reply, :insika_reply,
    :status, :verdict, :criterion_sha, :created_at, :updated_at
  )

  def pair(status: :judged, outcome: "comparable", vs: "agent", agent: "agent-store-ocean-drop",
           created_at: "2026-08-10T10:00:00Z", sha: CRITERION.sha, id: nil)
    verdict = { "outcome" => outcome, "reason" => "r", "vs" => vs, "judges" => [],
                "order_dependent" => false, "models" => %w[m1 m2 m3],
                "judged_at" => "2026-08-10T10:00:00Z" }
    ParityPair.new(
      id: id || SecureRandom.hex(8), channel: "relay", agent: agent,
      session_id: "relay:5511999998888", task_id: "t-1", event_id: "wamid.HBg",
      inbound: "queria saber do pedido", incumbent_reply: "me passa o número?",
      insika_reply: "já confiro pra você", status: status,
      verdict: %i[judged].include?(status) ? verdict : nil,
      criterion_sha: sha, created_at: created_at, updated_at: created_at
    )
  end

  # 7 days × 35 pairs, mixed buckets — a :pass window (see fixtures/parity/window.json).
  def fixture_pairs
    JSON.parse(File.read(File.expand_path("../../fixtures/parity/window.json", __dir__)))["pairs"]
        .map do |h|
      h = h.transform_keys(&:to_sym)
      ParityPair.new(**h.merge(status: h[:status].to_sym,
                         criterion_sha: h[:criterion_sha] == "stamped" ? CRITERION.sha : h[:criterion_sha]))
    end
  end

  describe "wilson_lower" do
    it "matches published reference values (n=210, k=183 -> ~0.819)" do
      expect(described_class.wilson_lower(183, 210)).to be_within(0.001).of(0.819)
    end

    it "is 0 for no successes, 1 for a clean sweep at large n" do
      expect(described_class.wilson_lower(0, 100)).to eq(0.0)
      expect(described_class.wilson_lower(100, 100)).to be_within(0.02).of(0.95)
    end

    it "is 0 for an empty sample" do
      expect(described_class.wilson_lower(0, 0)).to eq(0.0)
    end
  end

  # Spreads pairs evenly across the 7 window days (>= the daily floor), so the
  # volume check passes and the case under test is the only failing check.
  def spread(pairs)
    dates = (0...7).map { |d| format("2026-08-%02d", 8 + d) }
    pairs.each_with_index.map do |p, i|
      ParityPair.new(**p.to_h.merge(created_at: format("#{dates[i % 7]}T13:%02d:00Z", i / 7)))
    end
  end

  describe "the fold" do
    # E3: the code reaches the same verdict the fixture's human readers recorded.
    it "reproduces the fixture's recorded verdict, byte-stable" do
      report = described_class.fold(pairs: fixture_pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:pass)
      expect(report.counts[:decided]).to eq(200)
      expect(report.win_or_tie).to be_within(0.001).of(0.94)
      expect(report.worse_rate).to be_within(0.001).of(0.06)
      expect(report.undecided_rate).to be_within(0.001).of(15.0 / 215)
      expect(report.incomplete_rate).to be_within(0.001).of(5.0 / 240)
      # the arithmetic, not just the conclusion
      expect(report.checks.map { |c| [c.id, c.met] }).to all(satisfy { |_, met| met })
      expect(report.checks.map(&:id)).to include(:primary, :worse_rate, :undecided, :incomplete, :volume)
    end

    it "never counts silent or human-assisted pairs in the primary number" do
      report = described_class.fold(pairs: fixture_pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.counts[:silent]).to eq(10)
      expect(report.counts[:human_assisted]).to eq(10)
      expect(report.counts[:decided]).to eq(200)
    end

    it "reports per-store arithmetic, excluding out-of-window pairs" do
      old = pair(created_at: "2026-08-01T00:00:00Z", id: "old")
      report = described_class.fold(pairs: fixture_pairs + [old], criterion: CRITERION, now: FIXED_NOW)
      expect(report.per_agent["agent-store-ocean-drop"][:decided]).to eq(200)
      expect(report.window[:from]).to eq((FIXED_NOW - 7 * 86_400).iso8601)
    end

    it "reports :invalid by mixed sha — no verdict, no rates" do
      pairs = fixture_pairs + [pair(created_at: "2026-08-10T10:00:00Z", sha: "sha256:deadbeef", id: "forged")]
      report = described_class.fold(pairs: pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:invalid)
      expect(report.reason).to include(CRITERION.sha)
      expect(report.counts).to be_nil
      expect(report.win_or_tie).to be_nil
    end

    it "reports :invalid when the panel cannot decide (>20% split+unknown)" do
      undecided = spread(Array.new(210) { |i| pair(id: "d#{i}") } +
                         Array.new(50) { |i| pair(outcome: "split", id: "s#{i}") } +
                         Array.new(20) { |i| pair(outcome: "unknown", id: "u#{i}") })
      report = described_class.fold(pairs: undecided, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:invalid)
      expect(report.reason).to include("undecided")
    end

    it "reports :invalid when the mirror cannot pair (>20% incomplete)" do
      broken = spread(Array.new(200) { |i| pair(id: "d#{i}") } +
                      Array.new(60) { |i| pair(status: :incomplete, outcome: nil, id: "i#{i}") })
      report = described_class.fold(pairs: broken, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:invalid)
      expect(report.reason).to include("incomplete")
    end

    it "reports :insufficient — never :fail — on a gap day, naming the date" do
      pairs = fixture_pairs.reject { |p| p.created_at.start_with?("2026-08-11") }
      report = described_class.fold(pairs: pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:insufficient)
      expect(report.reason).to include("2026-08-11")
    end

    it "reports :insufficient when total decided pairs are short" do
      short = spread(Array.new(210) { |i| pair(status: :silent, outcome: nil, id: "s#{i}") })
      report = described_class.fold(pairs: short, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:insufficient)
      expect(report.reason).to include("decided")
    end

    it "reports :fail when the wilson lower bound is below the floor" do
      losers = spread(Array.new(210) { |i| pair(outcome: "worse", id: "w#{i}") })
      report = described_class.fold(pairs: losers, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:fail)
      expect(report.checks.find { |c| c.id == :primary }.met).to be(false)
    end

    it "reports :fail when worse_rate exceeds its ceiling (even with the floor cleared)" do
      tail = spread(Array.new(260) { |i| pair(outcome: "better", id: "t#{i}") } +
                    Array.new(40) { |i| pair(outcome: "worse", id: "w#{i}") })
      report = described_class.fold(pairs: tail, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:fail)
      expect(report.checks.find { |c| c.id == :worse_rate }.met).to be(false)
      expect(report.checks.find { |c| c.id == :primary }.met).to be(true)
    end

    it "reports :fail when ONE store blocks its own cut, naming the agent" do
      good = spread(Array.new(360) { |i| pair(id: "g#{i}") } +
                    Array.new(60) { |i| pair(agent: "agent-loja-ruim", outcome: "worse", id: "b#{i}") })
      report = described_class.fold(pairs: good, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:fail)
      expect(report.reason).to include("agent-loja-ruim")
      expect(report.per_agent["agent-loja-ruim"][:meets]).to be(false)
    end

    it "ignores the per-agent guard for a store below per_agent_min_decided" do
      good = spread(Array.new(210) { |i| pair(id: "g#{i}") } +
                    Array.new(10) { |i| pair(agent: "agent-novo", outcome: "worse", id: "n#{i}") })
      report = described_class.fold(pairs: good, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:pass)
      expect(report.per_agent["agent-novo"][:meets]).to be_nil
    end

    it "treats a malformed verdict blob as :unknown, never a preference" do
      broken = ParityPair.new(**pair(id: "broken").to_h.merge(status: :judged, verdict: "not a hash"))
      pairs = fixture_pairs.first(29) + [broken]
      report = described_class.fold(pairs: pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.counts[:unknown]).to eq(1)
      expect(report.counts[:decided]).to eq(29)
    end

    # 48 pairs/day over 7 days — constant traffic above the floor. The window
    # cuts the first and last calendar days in half, so the volume check must
    # hold only FULL days to the floor: the pre-fix bucketing anchored days at
    # `from`'s time of day, dropped the newest pairs off the grid entirely, and
    # made :pass unreachable below 2 × the floor.
    def constant_traffic_pairs
      stamps = (12..23).map { |h| format("2026-08-08T%02d:00:00Z", h) } +
               (9..14).flat_map { |d| (0..23).map { |h| format("2026-08-%02dT%02d:00:00Z", d, h) } } +
               (0..11).map { |h| format("2026-08-15T%02d:00:00Z", h) }
      # 2 pairs per hour = 48/day: 24 in the first boundary day, 48 × 6 full
      # days, 24 in the last boundary day -> 336 in window.
      stamps.each_with_index.flat_map do |t, i|
        [pair(id: "c#{i}a", created_at: t), pair(id: "c#{i}b", created_at: t)]
      end
    end

    it "reaches :pass at constant traffic above the floor — nothing dropped off the daily grid" do
      report = described_class.fold(pairs: constant_traffic_pairs, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:pass)
      expect(report.daily.map { |d| d[:pairs] }.sum).to eq(336)
      expect(report.daily.last[:date]).to eq("2026-08-15")
      expect(report.checks.find { |c| c.id == :volume }.met).to be(true)
    end

    it "reports :invalid when no pair carries a criterion_sha — nothing stamped, no verdict" do
      unstamped = constant_traffic_pairs.map { |p| ParityPair.new(**p.to_h.merge(criterion_sha: nil)) }
      report = described_class.fold(pairs: unstamped, criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:invalid)
      expect(report.reason).to include("predates the freeze")
      expect(report.counts).to be_nil
    end

    it "keeps :insufficient (not :invalid) for an empty window — there is nothing to pre-register" do
      report = described_class.fold(pairs: [], criterion: CRITERION, now: FIXED_NOW)
      expect(report.verdict).to eq(:insufficient)
      expect(report.checks.find { |c| c.id == :criterion_sha }.met).to be(true)
    end
  end

  describe "Parity.transcript" do
    it "formats both halves identically, so the judge cannot tell them apart by shape" do
      expect(Insika::Parity.transcript("cadê meu pedido", "já vejo")).to eq(
        "customer: cadê meu pedido\nassistant: já vejo"
      )
    end
  end
end
