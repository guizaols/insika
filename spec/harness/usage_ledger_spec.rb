# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::UsageLedger do
  subject(:ledger) { described_class.new(store: store) }

  let(:store) { Harness::Stores::Memory.new }
  let(:t0) { Time.at(1_000_200) } # multiple of 60 — the exact start of a 60s window

  it "add accumulates within the same window and returns the new total" do
    expect(ledger.add("chat", "c1", window: 60, now: t0)).to eq(1)
    expect(ledger.add("chat", "c1", window: 60, now: t0 + 30)).to eq(2)
    expect(ledger.count("chat", "c1", window: 60, now: t0 + 59)).to eq(2)
  end

  it "add with by: accumulates arbitrary amounts (the token ledger)" do
    ledger.add("tokens", "bia", window: 60, by: 500, now: t0)
    expect(ledger.add("tokens", "bia", window: 60, by: 250, now: t0)).to eq(750)
  end

  it "a new window starts from zero (fixed-window rollover)" do
    ledger.add("chat", "c1", window: 60, now: t0)
    expect(ledger.count("chat", "c1", window: 60, now: t0 + 60)).to eq(0)
    expect(ledger.add("chat", "c1", window: 60, now: t0 + 60)).to eq(1)
  end

  it "counters are independent per (kind, id)" do
    ledger.add("chat", "c1", window: 60, now: t0)
    expect(ledger.count("chat", "c2", window: 60, now: t0)).to eq(0)
    expect(ledger.count("tokens", "c1", window: 60, now: t0)).to eq(0)
  end

  it "add garbage-collects the pair's previous window key (bounded growth)" do
    ledger.add("chat", "c1", window: 60, now: t0)
    ledger.add("chat", "c1", window: 60, now: t0 + 60)
    ledger.add("chat", "c1", window: 60, now: t0 + 120)
    keys = store.list(described_class::SCOPE)
    expect(keys.size).to eq(1) # only the current window survives
    expect(keys.first).to start_with("chat:c1:")
  end

  it "works identically on the SQLite backend (the durable production path)" do
    sqlite = Harness::Stores::SQLite.new(path: ":memory:")
    durable = described_class.new(store: sqlite)
    durable.add("chat", "c1", window: 60, now: t0)
    expect(durable.add("chat", "c1", window: 60, now: t0)).to eq(2)
    expect(durable.count("chat", "c1", window: 60, now: t0 + 60)).to eq(0)
  ensure
    sqlite&.close
  end
end
