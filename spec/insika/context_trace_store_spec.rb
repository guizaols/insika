# frozen_string_literal: true

require "spec_helper"

# Per-session context breakdown (RFC-0023): tokens by category + budget per
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
end
