# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Insika::BudgetLedger do
  subject(:ledger) { described_class.new(store: store) }

  let(:store) { Insika::Stores::Memory.new }
  # Tuesday 2026-08-11 12:00 UTC — mid-month, mid-day.
  let(:now) { Time.utc(2026, 8, 11, 12, 0, 0) }

  it "add accumulares both windows and returns the new totals" do
    expect(ledger.add(tenant: "loja-42", agent: "atendente", by: 500, now: now))
      .to eq(daily: 500, monthly: 500)
    expect(ledger.add(tenant: "loja-42", agent: "atendente", by: 250, now: now + 3600))
      .to eq(daily: 750, monthly: 750)
  end

  it "cells are independent per (tenant, agent)" do
    ledger.add(tenant: "loja-42", agent: "atendente", by: 500, now: now)
    expect(ledger.current(tenant: "loja-42", agent: "atendente", now: now)).to eq(daily: 500, monthly: 500)
    expect(ledger.current(tenant: "loja-42", agent: "outro", now: now)).to eq(daily: 0, monthly: 0)
    expect(ledger.current(tenant: "loja-99", agent: "atendente", now: now)).to eq(daily: 0, monthly: 0)
  end

  it "daily window rolls over at the calender day boundary" do
    ledger.add(tenant: nil, agent: "a", by: 900, now: now)
    expect(ledger.current(tenant: nil, agent: "a", now: Time.utc(2026, 8, 11, 23, 59)))
      .to eq(daily: 900, monthly: 900)
    expect(ledger.current(tenant: nil, agent: "a", now: Time.utc(2026, 8, 12, 0, 0)))
      .to eq(daily: 0, monthly: 900)
  end

  it "monthly window rolls over at the calendar month boundary (28-day Feb != 31-day Jan)" do
    jan_end = Time.utc(2026, 1, 31, 12, 0, 0)
    feb_start = Time.utc(2026, 2, 1, 0, 0, 0)
    ledger.add(tenant: "t", agent: "a", by: 42, now: jan_end)
    expect(ledger.current(tenant: "t", agent: "a", now: jan_end)).to eq(daily: 42, monthly: 42)
    expect(ledger.current(tenant: "t", agent: "a", now: feb_start)).to eq(daily: 0, monthly: 0)
  end

  it "a nil tenant is a literal platform cell, not a null-key collision" do
    ledger.add(tenant: nil, agent: "a", by: 10, now: now)
    ledger.add(tenant: "x", agent: "a", by: 20, now: now)
    expect(ledger.current(tenant: nil, agent: "a", now: now)).to eq(daily: 10, monthly: 10)
    expect(ledger.current(tenant: "x", agent: "a", now: now)).to eq(daily: 20, monthly: 20)
  end

  it "add garbage-collects the previous day and month cells (bounded growth)" do
    ledger.add(tenant: "t", agent: "a", by: 1, now: Time.utc(2026, 7, 31, 23, 0))
    ledger.add(tenant: "t", agent: "a", by: 1, now: Time.utc(2026, 8, 1, 1, 0))
    ledger.add(tenant: "t", agent: "a", by: 1, now: Time.utc(2026, 8, 2, 1, 0))
    keys = store.list(described_class::SCOPE)
    expect(keys.size).to eq(2) # the current day cell + the current month cell
    expect(keys.first).to include("t:a:")
  end

  it "alert markers are per (tenant, agent, window, bucket): once per window, dying with it" do
    expect(ledger.alerted?(tenant: "t", agent: "a", window: :daily, now: now)).to be(false)

    expect(ledger.mark_alert(tenant: "t", agent: "a", window: :daily, now: now)).to be(false) # 1st
    expect(ledger.mark_alert(tenant: "t", agent: "a", window: :daily, now: now + 3_600)).to be(true) # already
    expect(ledger.alerted?(tenant: "t", agent: "a", window: :daily, now: now)).to be(true)

    # the next day the marker is gone (the window rolled): a fresh warn is allowed
    expect(ledger.alerted?(tenant: "t", agent: "a", window: :daily, now: now + described_class::DAY)).to be(false)
    # other scopes are independent
    expect(ledger.alerted?(tenant: "t", agent: "b", window: :daily, now: now)).to be(false)
    expect(ledger.alerted?(tenant: "t", agent: "a", window: :monthly, now: now)).to be(false)
  end

  it "reset_in counts down to the window roll (retry_after for a hard budget)" do
    expect(ledger.reset_in(:daily, now: Time.utc(2026, 8, 11, 12, 0, 0))).to eq(43_200) # 12h left
    expect(ledger.reset_in(:daily, now: Time.utc(2026, 8, 11, 0, 0, 0))).to eq(86_400) # a full day
    expect(ledger.reset_in(:monthly, now: Time.utc(2026, 8, 11, 0, 0, 0))).to eq(21 * described_class::DAY) # Aug 11 -> Sep 1
  end

  it "two SQLite handles racing the same cell lose nothing (exactly one increment per call)" do
    dir = Dir.mktmpdir
    path = File.join(dir, "budget.db")
    a = Insika::Stores::SQLite.new(path: path)
    b = Insika::Stores::SQLite.new(path: path)
    la = described_class.new(store: a)
    lb = described_class.new(store: b)

    threads = [la, lb].map do |ledger_handle|
      Thread.new { 5.times { ledger_handle.add(tenant: "t", agent: "a", by: 100, now: now) } }
    end
    threads.each(&:join)

    expect(la.current(tenant: "t", agent: "a", now: now)).to eq(daily: 1000, monthly: 1000)
    expect(lb.current(tenant: "t", agent: "a", now: now)).to eq(daily: 1000, monthly: 1000)
  ensure
    a&.close
    b&.close
  end
end