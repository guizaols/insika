# frozen_string_literal: true

require "spec_helper"

#   — the per-AGENT cache-hit series (scope "cache_series"). Sessions
# do not stamp their agent, so the per-session context trace cannot answer
# "cache-hit over time for THIS agent"; this capped list can. Entries are
# counts and a category name only — PII-free by construction.
RSpec.describe Insika::CacheSeriesStore do
  subject(:store) { described_class.new(store: Insika::Stores::Memory.new) }

  def entry(**over)
    { at: "2026-08-15T10:00:00Z", turn: 2, hit_pct: 83, cached_tokens: 21_845,
      prompt_tokens: 26_319, invalidation_reason: "memory" }.merge(over)
  end

  it "records and reads the coerced entry per agent, chronological" do
    store.record(agent: "bia", entry: entry(turn: 1, hit_pct: "80"))
    store.record(agent: "bia", entry: entry(turn: 2))
    got = store.for_agent("bia")
    expect(got.size).to eq(2)
    expect(got.first).to eq("at" => "2026-08-15T10:00:00Z", "turn" => 1, "hit_pct" => 80,
                            "cached_tokens" => 21_845, "prompt_tokens" => 26_319,
                            "invalidation_reason" => "memory")
  end

  it "agents do not mix" do
    store.record(agent: "bia", entry: entry(turn: 1))
    store.record(agent: "chef", entry: entry(turn: 1, hit_pct: 10))
    expect(store.for_agent("bia").size).to eq(1)
    expect(store.for_agent("chef").first["hit_pct"]).to eq(10)
    expect(store.for_agent("nada")).to eq([])
  end

  it "nil fields are coerced honestly (nil stays nil, absent becomes 0)" do
    store.record(agent: "bia", entry: entry(hit_pct: nil, invalidation_reason: nil, turn: nil))
    got = store.for_agent("bia").first
    expect(got["hit_pct"]).to be_nil
    expect(got["invalidation_reason"]).to be_nil
    expect(got["turn"]).to eq(0)
  end

  it "the 201st entry drops the oldest (rolling window, one entry per turn)" do
    (described_class::MAX_PER_AGENT + 1).times do |i|
      store.record(agent: "bia", entry: entry(turn: i))
    end
    got = store.for_agent("bia")
    expect(got.size).to eq(described_class::MAX_PER_AGENT)
    expect(got.first["turn"]).to eq(1)
    expect(got.last["turn"]).to eq(described_class::MAX_PER_AGENT)
  end

  it "a blank agent id is a no-op" do
    store.record(agent: "", entry: entry)
    expect(store.for_agent("")).to eq([])
  end

  it "a raising backend is a no-op (the series never breaks the turn)" do
    boom = Object.new
    def boom.get(*) = raise("db down")
    def boom.set(*) = raise("db down")
    s = described_class.new(store: boom)
    expect { s.record(agent: "bia", entry: entry) }.not_to raise_error
  end
end
