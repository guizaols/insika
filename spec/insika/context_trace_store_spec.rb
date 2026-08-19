# frozen_string_literal: true

require "spec_helper"

# Per-session context breakdown: tokens by category + budget per
# turn, for the Studio session card. Counts and provider ids only — no content.
RSpec.describe Insika::ContextTraceStore do
  subject(:store) { described_class.new(store: Insika::Stores::Memory.new) }

  def entry(**over)
    { task_id: "t1", turn: 1, at: "2026-08-10T00:00:00Z",
      cap: 8_000, used: 6_120, evicted: ["session"],
      categories: { "prompt" => { tokens: 4_100, fragments: 2, pinned: 4_100 },
                    "session" => { tokens: 1_900, fragments: 1, pinned: 0 } },
      tools: { count: 9, tokens: 1_200 } }.merge(over)
  end

  it "records and reads per session in chronological order, numbers coerced" do
    store.record(session_id: "s1", entry: entry(turn: 1))
    store.record(session_id: "s1", entry: entry(task_id: "t2", turn: 1))
    got = store.for_session("s1")
    expect(got.size).to eq(2)
    expect(got.first).to include("task_id" => "t1", "turn" => 1, "cap" => 8_000,
                                 "used" => 6_120, "evicted" => ["session"])
    expect(got.first["categories"]["prompt"]).to eq(
      { "tokens" => 4_100, "fragments" => 2, "pinned" => 4_100 }
    )
    expect(got.first["tools"]).to eq({ "count" => 9, "tokens" => 1_200 })
  end

  # {name, reason}: the reason is what makes the card answer "which one did I
  # trigger", and it has to survive the JSON round-trip through the store.
  describe "activation labels" do
    def labels_of(cats)
      store.record(session_id: "s", entry: entry(categories: cats))
      store.for_session("s").first["categories"]["skilltrigger"]["labels"]
    end

    it "keeps name and reason, symbol or string keys in" do
      got = labels_of("skilltrigger" => { tokens: 1, fragments: 1, pinned: 0,
                                          labels: [{ name: "presente", reason: "trigger:presente" },
                                                   { "name" => "formato", "reason" => "eager" }] })

      expect(got).to eq([{ "name" => "presente", "reason" => "trigger:presente" },
                         { "name" => "formato", "reason" => "eager" }])
    end

    it "a bare string still reads as a label (a reason-less caller degrades the card, never poisons it)" do
      got = labels_of("skilltrigger" => { tokens: 1, fragments: 1, pinned: 0, labels: ["mapa"] })

      expect(got).to eq([{ "name" => "mapa" }])
    end

    it "drops a nameless label and de-duplicates the rest" do
      got = labels_of("skilltrigger" => { tokens: 1, fragments: 1, pinned: 0,
                                          labels: [{ "reason" => "eager" }, "mapa", "mapa"] })

      expect(got).to eq([{ "name" => "mapa" }])
    end

    it "a category with nothing to name carries no labels key (no noise)" do
      store.record(session_id: "s", entry: entry)

      expect(store.for_session("s").first["categories"]["prompt"]).not_to have_key("labels")
    end
  end

  it "upserts by (task_id, turn): a resumed turn re-records, never duplicates" do
    store.record(session_id: "s1", entry: entry(used: 100))
    store.record(session_id: "s1", entry: entry(used: 200))
    got = store.for_session("s1")
    expect(got.size).to eq(1)
    expect(got.first["used"]).to eq(200)
  end

  it "session without a trace -> []" do
    expect(store.for_session("nada")).to eq([])
  end

  it "empty session_id -> no-op" do
    store.record(session_id: "", entry: entry)
    expect(store.for_session("")).to eq([])
  end

  it "a raising backend -> no-op (the trace never breaks the turn)" do
    boom = Object.new
    def boom.get(*) = raise("db down")
    def boom.set(*) = raise("db down")
    s = described_class.new(store: boom)
    expect { s.record(session_id: "s", entry: entry) }.not_to raise_error
  end

  it "caps the per-session list (does not grow unbounded)" do
    (described_class::MAX_PER_SESSION + 10).times do |i|
      store.record(session_id: "s", entry: entry(task_id: "t#{i}"))
    end
    got = store.for_session("s")
    expect(got.size).to eq(described_class::MAX_PER_SESSION)
    expect(got.last["task_id"]).to eq("t#{described_class::MAX_PER_SESSION + 9}")
  end

  it "clear removes the session's trace" do
    store.record(session_id: "s", entry: entry)
    expect(store.clear("s")).to be(true)
    expect(store.for_session("s")).to eq([])
  end

  describe "fingerprints + cache fields" do
    it "fingerprints round-trip: only string keys with hex values" do
      store.record(session_id: "s", entry: entry(fingerprints: {
                    "prompt" => "a1b2c3", "memory" => "d4e5f6", "prefix" => "ff00ff"
                  }))
      got = store.for_session("s").first
      expect(got["fingerprints"]).to eq("prompt" => "a1b2c3", "memory" => "d4e5f6", "prefix" => "ff00ff")
    end

    it "non-string fingerprint values are dropped" do
      store.record(session_id: "s", entry: entry(fingerprints: { "a" => 123, "b" => "ok" }))
      got = store.for_session("s").first
      expect(got["fingerprints"]).to eq("b" => "ok")
    end

    it "cache block round-trips: hit_pct, cached_tokens, prompt_tokens, invalidation_reason" do
      store.record(session_id: "s", entry: entry(cache: { hit_pct: 83, cached_tokens: 21_845,
                                                          prompt_tokens: 26_319, invalidation_reason: "memory" }))
      got = store.for_session("s").first
      expect(got["cache"]).to eq("hit_pct" => 83, "cached_tokens" => 21_845,
                                 "prompt_tokens" => 26_319, "invalidation_reason" => "memory")
    end

    it "an entry without cache reads back without it (backward compat)" do
      store.record(session_id: "s", entry: entry)
      expect(store.for_session("s").first).not_to have_key("cache")
    end

    it "cache with nil invalidation_reason is stored as nil (not dropped)" do
      store.record(session_id: "s", entry: entry(cache: { hit_pct: 50, invalidation_reason: nil }))
      expect(store.for_session("s").first.dig("cache", "invalidation_reason")).to be_nil
    end

    it "category layer round-trips: identity or volatile" do
      store.record(session_id: "s", entry: entry(categories: {
                    "prompt" => { tokens: 100, fragments: 1, pinned: 100, layer: "identity" },
                    "memory" => { tokens: 50, fragments: 1, pinned: 0, layer: "volatile" }
                  }))
      cats = store.for_session("s").first["categories"]
      expect(cats["prompt"]["layer"]).to eq("identity")
      expect(cats["memory"]["layer"]).to eq("volatile")
    end

    it "a category without layer gets no key (nil becomes absent)" do
      store.record(session_id: "s", entry: entry(categories: {
                    "prompt" => { tokens: 100, fragments: 1, pinned: 100 }
                  }))
      expect(store.for_session("s").first["categories"]["prompt"]).not_to have_key("layer")
    end

    it "record returns the sanitized entry (C5 parks it for the stage-8 merge)" do
      result = store.record(session_id: "s", entry: entry(turn: 1, used: 100))
      expect(result).to be_a(Hash)
      expect(result["used"]).to eq(100)
      expect(result["task_id"]).to eq("t1")
    end
  end
end
