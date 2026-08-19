# frozen_string_literal: true

require "spec_helper"

# the durable aggregates of the outcome funnel — per-day stage
# counts, the fold cursor and the baseline snapshot. Dumb domain store: it
# holds no outcome_store and never folds (C4 owns the transformation), and it
# is recomputable by construction — the OutcomeStore stays the source of truth.
RSpec.describe Insika::FunnelStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }

  let(:at) { Time.iso8601("2026-08-14T10:00:00Z") }

  describe "#add (cumulative day counts, D2)" do
    it "bumps exactly the stages of the reached prefix" do
      returned = store.add(tenant: "acme", agent: "store-support", at: at,
                           counts: { "greeted" => 1, "qualified" => 1 })
      expect(returned).to eq("greeted" => 1, "qualified" => 1)
      expect(store.day(tenant: "acme", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 1, "qualified" => 1)
    end

    it "accumulates same-day events" do
      store.add(tenant: "acme", agent: "a", at: at, counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: at, counts: { "greeted" => 1, "qualified" => 1 })
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14"))
        .to eq("greeted" => 2, "qualified" => 1)
    end

    it "two events on different days land in different cells" do
      store.add(tenant: "acme", agent: "a", at: at, counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-15T09:00:00Z"),
                counts: { "greeted" => 1 })
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14")["greeted"]).to eq(1)
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-15")["greeted"]).to eq(1)
    end

    it "stages after the reached index stay untouched" do
      store.add(tenant: "acme", agent: "a", at: at, counts: { "cart" => 1 })
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14"))
        .to eq("cart" => 1)
    end

    it "normalizes a blank tenant to the literal 'platform' cell" do
      store.add(tenant: nil, agent: "a", at: at, counts: { "greeted" => 1 })
      expect(store.day(tenant: nil, agent: "a", day: "2026-08-14")["greeted"]).to eq(1)
      expect(store.day(tenant: "platform", agent: "a", day: "2026-08-14")["greeted"]).to eq(1)
      expect(store.day(tenant: "", agent: "a", day: "2026-08-14")["greeted"]).to eq(1)
    end
  end

  describe "#days (the Studio's period window)" do
    before do
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-10T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                counts: { "greeted" => 1, "paid" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-16T10:00:00Z"),
                counts: { "greeted" => 1 })
    end

    it "returns days sorted ascending, bounded by inclusive from/to" do
      days = store.days(tenant: "acme", agent: "a", from: "2026-08-14", to: "2026-08-16")
      expect(days.keys).to eq(%w[2026-08-14 2026-08-16])
      expect(days["2026-08-14"]).to eq("greeted" => 1, "paid" => 1)
    end

    it "unbounded reads the whole span" do
      expect(store.days(tenant: "acme", agent: "a").keys).to eq(%w[2026-08-10 2026-08-14 2026-08-16])
    end

    it "empty store -> {}" do
      expect(store.days(tenant: "acme", agent: "nobody")).to eq({})
      expect(store.days(tenant: "acme", agent: "nobody", from: "2026-01-01", to: "2026-12-31")).to eq({})
    end

    it "malformed from/to strings read as unbounded (tolerant)" do
      expect(store.days(tenant: "acme", agent: "a", from: "not-a-date", to: "x").keys.size).to eq(3)
    end
  end

  describe "#cursor (the fold's {at, ids})" do
    it "starts empty" do
      expect(store.cursor(tenant: "acme", agent: "a"))
        .to eq("at" => nil, "ids" => [])
    end

    it "round-trips" do
      store.set_cursor(tenant: "acme", agent: "a", at: "2026-08-14T21:03:07Z", ids: %w[9f2 1ab])
      expect(store.cursor(tenant: "acme", agent: "a"))
        .to eq("at" => "2026-08-14T21:03:07Z", "ids" => %w[9f2 1ab])
    end

    it "is per pair (another agent's cursor is untouched)" do
      store.set_cursor(tenant: "acme", agent: "a", at: "2026-08-14T21:03:07Z", ids: [])
      expect(store.cursor(tenant: "acme", agent: "b")["at"]).to be_nil
    end
  end

  describe "#baseline (D5 — one current snapshot per pair)" do
    let(:record) do
      { "from" => "2026-07-14", "to" => "2026-08-14",
        "stages" => { "greeted" => 1290, "paid" => 7 }, "primary" => "paid",
        "primary_count" => 7, "conversion" => 0.0054, "window" => "72h",
        "frozen_at" => "2026-08-15T10:00:00Z" }
    end

    it "nil when never frozen" do
      expect(store.baseline(tenant: "acme", agent: "a")).to be_nil
    end

    it "set/get round-trips verbatim" do
      store.set_baseline(tenant: "acme", agent: "a", record: record)
      expect(store.baseline(tenant: "acme", agent: "a")).to eq(record)
    end

    it "overwrites (no history)" do
      store.set_baseline(tenant: "acme", agent: "a", record: record)
      store.set_baseline(tenant: "acme", agent: "a", record: record.merge("frozen_at" => "2026-09-01T00:00:00Z"))
      expect(store.baseline(tenant: "acme", agent: "a")["frozen_at"]).to eq("2026-09-01T00:00:00Z")
      expect(store.baseline(tenant: "acme", agent: "b")).to be_nil
    end
  end

  describe "#purge (tenant isolation — the key IS the boundary)" do
    before do
      store.add(tenant: "acme", agent: "a", at: at, counts: { "greeted" => 1 })
      store.set_cursor(tenant: "acme", agent: "a", at: "2026-08-14T21:03:07Z", ids: ["x"])
      store.set_baseline(tenant: "acme", agent: "a", record: { "frozen_at" => "x" })
      store.add(tenant: "zed", agent: "a", at: at, counts: { "greeted" => 5 })
    end

    it "removes cells + cursor + baseline of one tenant, leaves the neighbour" do
      removed = store.purge(tenant: "acme")
      expect(removed).to eq(3)
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14")).to eq({})
      expect(store.cursor(tenant: "acme", agent: "a")["at"]).to be_nil
      expect(store.baseline(tenant: "acme", agent: "a")).to be_nil
      expect(store.day(tenant: "zed", agent: "a", day: "2026-08-14")).to eq("greeted" => 5)
    end

    it "a blank-tenant write lands in the 'platform' cell that purge(platform) reaches" do
      store.add(tenant: nil, agent: "b", at: at, counts: { "greeted" => 1 })
      expect(store.purge(tenant: "platform")).to eq(1)
      expect(store.day(tenant: nil, agent: "b", day: "2026-08-14")).to eq({})
    end
  end

  describe "#delete_older_than (retention — DAY CELLS only)" do
    before do
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-07-01T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.set_cursor(tenant: "acme", agent: "a", at: "2026-01-01T00:00:00Z", ids: ["old"])
      store.set_baseline(tenant: "acme", agent: "a", record: { "frozen_at" => "2026-01-01T00:00:00Z" })
    end

    it "sweeps old day cells, keeps newer ones, never touches cursor/baseline" do
      cutoff = Time.iso8601("2026-08-01T00:00:00Z")
      removed = store.delete_older_than(cutoff)
      expect(removed).to eq(1)
      expect(store.day(tenant: "acme", agent: "a", day: "2026-07-01")).to eq({})
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14")["greeted"]).to eq(1)
      expect(store.cursor(tenant: "acme", agent: "a")["at"]).to eq("2026-01-01T00:00:00Z")
      expect(store.baseline(tenant: "acme", agent: "a")["frozen_at"]).to eq("2026-01-01T00:00:00Z")
    end
  end

  describe "#delete_days (— the recompute repair's wipe)" do
    before do
      store.add(tenant: nil, agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.add(tenant: nil, agent: "a", at: Time.iso8601("2026-08-15T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-14T10:00:00Z"),
                counts: { "greeted" => 5 })
    end

    it "wipes ONE pair's day cells, leaves the neighbour and the cursor" do
      store.set_cursor(tenant: nil, agent: "a", at: "2026-08-15T10:00:00Z", ids: ["x"])
      removed = store.delete_days(tenant: nil, agent: "a")

      expect(removed).to eq(2)
      expect(store.day(tenant: nil, agent: "a", day: "2026-08-14")).to eq({})
      expect(store.day(tenant: nil, agent: "a", day: "2026-08-15")).to eq({})
      expect(store.day(tenant: "acme", agent: "a", day: "2026-08-14")["greeted"]).to eq(5)
      expect(store.cursor(tenant: nil, agent: "a")["at"]).to eq("2026-08-15T10:00:00Z")
    end

    it "all three no-tenant spellings reach the 'platform' cells" do
      expect(store.delete_days(tenant: "", agent: "a")).to eq(2)
      expect(store.delete_days(tenant: "platform", agent: "a")).to eq(0)
      expect(store.day(tenant: nil, agent: "a", day: "2026-08-14")).to eq({})
    end
  end

  describe "#pairs (the Studio's derived drill, D7)" do
    it "lists every (tenant, agent) with any day cell, deduped" do
      store.add(tenant: "acme", agent: "a", at: at, counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "a", at: Time.iso8601("2026-08-15T10:00:00Z"),
                counts: { "greeted" => 1 })
      store.add(tenant: "acme", agent: "b", at: at, counts: { "greeted" => 1 })
      store.add(tenant: "zed", agent: "a", at: at, counts: { "greeted" => 1 })

      expect(store.pairs).to contain_exactly(
        { tenant: "acme", agent: "a" }, { tenant: "acme", agent: "b" },
        { tenant: "zed", agent: "a" }
      )
    end

    it "empty -> []" do
      expect(store.pairs).to eq([])
    end
  end
end
