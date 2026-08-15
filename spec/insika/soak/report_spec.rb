# frozen_string_literal: true

require "spec_helper"
require "time"

FIXTURES = File.expand_path("../../fixtures/soak", __dir__)

RSpec.describe Insika::Soak::Report do
  def envelope = Insika::Soak::Envelope.load(File.join(FIXTURES, "envelope.md"))

  def records(name)
    File.foreach(File.join(FIXTURES, "#{name}.jsonl")).map { |l| JSON.parse(l) }
  end

  def fold(name, env = envelope)
    described_class.fold(records(name), envelope: env)
  end

  describe ".pct" do
    it "matches the loadtest.rb formula (linear interpolation, 1-decimal rounding)" do
      expect(described_class.pct([1.0, 2.0, 3.0, 4.0], 50)).to eq(2.5)
      expect(described_class.pct([1.0, 2.0, 3.0, 4.0], 95)).to eq(3.9)
      expect(described_class.pct([], 95)).to eq(0.0)
    end
  end

  describe ".trend" do
    it "returns the exact slope for a linear series" do
      t = described_class.trend([[0, 100.0], [10, 200.0]])
      expect(t[:slope]).to be_within(1e-9).of(10.0)
      expect(t[:intercept]).to be_within(1e-9).of(100.0)
    end

    it "has an upper 95% bound slightly above 0 for a flat series" do
      t = described_class.trend((0..65).map { |h| [h, 512.0] })
      expect(t[:slope]).to eq(0.0)
      expect(t[:upper_95]).to eq(0.0)
    end

    it "does not give noise-only data a significant slope" do
      rng = Random.new(7)
      points = (0..65).map { |h| [h, 512.0 + rng.rand(-0.5..0.5)] }
      t = described_class.trend(points)
      growth = (t[:intercept] + t[:upper_95] * 65) / t[:intercept]
      expect(growth).to be < 1.01
    end

    it "returns nil below two points" do
      expect(described_class.trend([[0, 1.0]])).to be_nil
      expect(described_class.trend([])).to be_nil
    end
  end

  describe ".fold" do
    it "raises ArgumentError for a non-Enumerable" do
      expect { described_class.fold(42, envelope: envelope) }.to raise_error(ArgumentError)
    end

    it "returns :insufficient for an empty record set" do
      result = described_class.fold([], envelope: envelope)
      expect(result.verdict).to eq(:insufficient)
    end

    describe "the committed fixtures" do
      it "green-72h → :pass" do
        result = fold("green-72h")
        expect(result.verdict).to eq(:pass)
        expect(result.reasons).to eq([])
        expect(result.metrics[:turns]).to eq(288)
        expect(result.metrics[:snapshots]).to eq(72)
        expect(result.metrics[:restarts]).to eq(0)
      end

      it "leak → :fail, reason names rss_growth_ratio and quotes the fitted slope" do
        result = fold("leak")
        expect(result.verdict).to eq(:fail)
        expect(result.reasons).to include(a_string_matching(/rss_growth_ratio/))
        expect(result.reasons.join(" ")).to match(/73\.2 MB\/day/)
      end

      it "restart → :fail, reason names the hour" do
        result = fold("restart")
        expect(result.verdict).to eq(:fail)
        expect(result.reasons).to include(a_string_matching(/boot_id changed at hour 30/))
      end

      it "worker-respawn → :fail (the case an external metrics API cannot see)" do
        result = fold("worker-respawn")
        expect(result.verdict).to eq(:fail)
        expect(result.reasons).to include(a_string_matching(/respawned at hour 30/))
      end

      it "blocked → :fail on no_usage_rate, NOT a pass" do
        result = fold("blocked")
        expect(result.verdict).to eq(:fail)
        expect(result.reasons).to include(a_string_matching(/no_usage_rate/))
        expect(result.metrics[:no_usage_rate]).to eq(1.0)
      end

      it "short → :insufficient, not :fail" do
        result = fold("short")
        expect(result.verdict).to eq(:insufficient)
        expect(result.reasons).to include(a_string_matching(/interrupted/))
      end

      it "tampered → :invalid, and no rates are reported at all" do
        result = fold("tampered")
        expect(result.verdict).to eq(:invalid)
        expect(result.reasons).to include(a_string_matching(/hour 40/))
        expect(result.metrics).to eq({})
      end
    end

    describe "inline verdict cases" do
      it ":invalid when the header hash does not match the envelope" do
        other = Insika::Soak::Envelope.parse(File.read(File.join(FIXTURES, "envelope.md")),
                                             sha: "sha256:other")
        expect(fold("green-72h", other).verdict).to eq(:invalid)
      end

      it ":invalid when a snapshot's hash disagrees with the header" do
        lines = records("green-72h")
        lines.find { |l| l["t"] == "snapshot" }["envelope_sha"] = "sha256:elsewhere"
        result = described_class.fold(lines, envelope: envelope)
        expect(result.verdict).to eq(:invalid)
      end

      it ":invalid when calibrated? is false on a non-dry run" do
        uncalibrated = Insika::Soak::Envelope.parse(
          File.read(File.join(FIXTURES, "envelope.md")).sub(/rss_ceiling_mb: 900/, "rss_ceiling_mb: "),
          sha: "sha256:x"
        )
        result = described_class.fold(records("green-72h"), envelope: uncalibrated)
        expect(result.verdict).to eq(:invalid)
      end

      it ":fail on prep_p95 drift beyond the ratio" do
        lines = records("green-72h")
        lines.each do |l|
          next unless l["t"] == "turn"

          hour = ((Time.parse(l["at"]) - Time.parse("2026-08-20T09:00:00Z")) / 3600).floor
          l["timing"]["prep_ms"] = hour >= 60 ? 2.0 : 0.4
        end
        result = described_class.fold(lines, envelope: envelope)
        expect(result.verdict).to eq(:fail)
        expect(result.reasons).to include(a_string_matching(/prep_p95_drift_ratio/))
      end

      it ":insufficient when a turn gap exceeds gap_seconds_max" do
        lines = records("green-72h")
        lines.each do |l|
          next unless l["t"] == "turn"

          l["at"] = (Time.parse(l["at"]) + 1200).iso8601 if l["at"] >= "2026-08-20T18:00:00Z"
        end
        result = described_class.fold(lines, envelope: envelope)
        expect(result.verdict).to eq(:insufficient)
        expect(result.reasons).to include(a_string_matching(/gap/))
        expect(result.metrics[:thin_hours]).to eq(0)
      end

      it ":insufficient when no turn carries timing data" do
        lines = records("green-72h")
        lines.each { |l| l["timing"] = nil if l["t"] == "turn" }
        result = described_class.fold(lines, envelope: envelope)
        expect(result.verdict).to eq(:insufficient)
      end
    end
  end

  describe "mechanical reading (E1 discard condition)" do
    it "folds the same bytes twice into byte-identical to_h" do
      lines = records("green-72h")
      a = described_class.fold(lines, envelope: envelope).to_h
      b = described_class.fold(records("green-72h"), envelope: envelope).to_h
      expect(JSON.generate(b)).to eq(JSON.generate(a))
    end
  end

  describe "Insika::Soak::Report::Result" do
    it "renders a human report and a verdict JSON body" do
      result = fold("green-72h")
      text = result.to_s
      expect(text).to include("PASS")
      expect(text).to include("fixture-72h")
      expect(result.to_h).to include("verdict" => "pass", "run_id" => "fixture-72h")
    end

    it "prints the leak-hunt starting point on a fail" do
      text = fold("leak").to_s
      expect(text).to include("leak hunt")
    end
  end
end
