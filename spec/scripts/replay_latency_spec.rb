# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../scripts/replay_latency"

#   — the E2 replay harness' arithmetic, so it cannot silently rot.
# No network, no provider, no staging: corpus parsing + percentiles + the report
# fold. The live before/after is a human-run measurement (script, not CI).
RSpec.describe "scripts/replay_latency.rb" do
  CORPUS = [
    { "id" => "greet-1", "external_id" => "replay-greet-1", "agent" => "store-support",
      "messages" => [{ "at_ms" => 0, "text" => "oi" }] },
    { "id" => "catalog-1", "external_id" => "replay-cat-1", "agent" => "store-support",
      "messages" => [{ "at_ms" => 0, "text" => "quero um vestido" },
                     { "at_ms" => 1800, "text" => "preto, m" }] }
  ].freeze

  describe "parse_corpus" do
    it "parses the recorded corpus shape" do
      cases = ReplayLatency.parse_corpus(JSON.generate(CORPUS))

      expect(cases.size).to eq(2)
      expect(cases.first["external_id"]).to eq("replay-greet-1")
      expect(cases.last["messages"].last).to include("at_ms" => 1800, "text" => "preto, m")
    end

    it "refuses a case without external_id (two cases would share one session)" do
      broken = CORPUS.map(&:dup).tap { |a| a.first.delete("external_id") }
      expect { ReplayLatency.parse_corpus(JSON.generate(broken)) }
        .to raise_error(/external_id/)
    end

    it "refuses an empty corpus and a shape that is not an array" do
      expect { ReplayLatency.parse_corpus("{}") }.to raise_error(/array/)
      expect { ReplayLatency.parse_corpus("[]") }.to raise_error(/at least 1 case/)
    end
  end

  describe "the report fold (median/p95)" do
    it "computes the median and p95 from per-case samples" do
      samples = [890, 1_740, 2_300, 3_100, 9_100]

      stats = ReplayLatency.statistics(samples)
      expect(stats["median_first_balloon_ms"]).to eq(2_300)
      expect(stats["p95_first_balloon_ms"]).to eq(9_100)
    end

    it "ignores cases that never got a delivery (a hole is not a zero)" do
      stats = ReplayLatency.statistics([890, nil, 1_740, nil])

      # nearest-rank over [890, 1740]: median = lower middle; p95 = the top
      expect(stats["median_first_balloon_ms"]).to eq(890)
      expect(stats["p95_first_balloon_ms"]).to eq(1_740)
    end

    it "is nil-safe on an empty sample set" do
      stats = ReplayLatency.statistics([])
      expect(stats["median_first_balloon_ms"]).to be_nil
      expect(stats["p95_first_balloon_ms"]).to be_nil
    end
  end

  describe "the report shape" do
    it "n, the stats and per_case rows, with a place for the human's discard" do
      report = {
        "n" => 16,
        **ReplayLatency.statistics([890, 1_740, 9_100]),
        "per_case" => [{ "id" => "greet-1", "first_balloon_ms" => 890, "balloons" => 1 }]
      }

      expect(report["n"]).to eq(16)
      expect(report["median_first_balloon_ms"]).to eq(1_740)
      expect(report["per_case"].first).to include("id" => "greet-1", "balloons" => 1)
    end
  end
end