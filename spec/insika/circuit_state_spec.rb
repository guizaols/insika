# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::CircuitState do
  subject(:circuit) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:t0) { Time.at(1_000_000) }
  # breaker config under test: after: 3, within: 60, cooldown: 300
  BREAKER_AFTER = 3; BREAKER_WITHIN = 60; BREAKER_COOLDOWN = 300

  def state(ref: "deepseek/deepseek-v4-flash", tenant: nil, now: t0)
    circuit.state(tenant: tenant, ref: ref, after: BREAKER_AFTER, within: BREAKER_WITHIN, cooldown: BREAKER_COOLDOWN, now: now)
  end

  def fail!(n = 1, ref: "deepseek/deepseek-v4-flash", tenant: nil, now: t0)
    n.times { circuit.record_failure(tenant: tenant, ref: ref, after: BREAKER_AFTER, within: BREAKER_WITHIN, now: now) }
  end

  it ":closed until the window count is met; the after-th failure trips it OPEN" do
    expect(state).to eq(:closed)
    fail!(2)
    expect(state).to eq(:closed)

    circuit.record_failure(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                           after: BREAKER_AFTER, within: BREAKER_WITHIN, now: t0 + 10)
    expect(state(now: t0 + 10)).to eq(:open)
    # at the trip instant the full cooldown is owed; 10s later 290 remain.
    expect(circuit.retry_after(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                               cooldown: BREAKER_COOLDOWN, now: t0 + 10)).to eq(BREAKER_COOLDOWN)
    expect(circuit.retry_after(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                               cooldown: BREAKER_COOLDOWN, now: t0 + 20)).to eq(BREAKER_COOLDOWN - 10)
  end

  it "the window is a ROLLING one: old failures age out of the count" do
    fail!(2, now: t0)
    fail!(1, now: t0 + c(60 + 5)) # the first two are outside the 60s window now
    # only the last failure is recent -> not open
    expect(state(now: t0 + c(60 + 5))).to eq(:closed)
  end

  it "after the COOLDOWN the circuit is :half_open (a trial is allowed)" do
    fail!(BREAKER_AFTER, now: t0)
    expect(state(now: t0 + BREAKER_COOLDOWN - 1)).to eq(:open)
    expect(state(now: t0 + BREAKER_COOLDOWN)).to eq(:half_open)
    expect(circuit.retry_after(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                               cooldown: BREAKER_COOLDOWN, now: t0 + BREAKER_COOLDOWN)).to be_nil
  end

  # The breaker is NOT one-shot: a half-open trial that fails must re-stamp
  # opened_at and reopen — otherwise, after the first cooldown, every later turn
  # is an unlocked half-open trial (the cell is disarmed forever, WS3).
  it "a FAILED half-open trial REOPENS the circuit (fresh cooldown owed), instead of staying half-open" do
    fail!(BREAKER_AFTER, now: t0) # opens at t0
    expect(state(now: t0 + BREAKER_COOLDOWN)).to eq(:half_open)

    circuit.record_failure(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                           after: BREAKER_AFTER, within: BREAKER_WITHIN,
                           now: t0 + BREAKER_COOLDOWN)

    # back to :open with a full new cooldown, immediately (not after another 60s amortization)
    expect(state(now: t0 + BREAKER_COOLDOWN + 1)).to eq(:open)
    expect(circuit.retry_after(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                               cooldown: BREAKER_COOLDOWN, now: t0 + BREAKER_COOLDOWN + 1))
      .to eq(BREAKER_COOLDOWN - 1)
  end

  it "a success CLOSES the circuit (half-open trial success); a failure reopens it" do
    fail!(BREAKER_AFTER, now: t0)
    circuit.record_success(tenant: nil, ref: "deepseek/deepseek-v4-flash")
    expect(state).to eq(:closed)

    fail!(BREAKER_AFTER, now: t0 + 1)
    expect(state(now: t0 + 1)).to eq(:open)
  end

  it "cells are independent per (tenant, ref)" do
    fail!(BREAKER_AFTER, tenant: "loja-a", ref: "deepseek/deepseek-v4-flash")
    expect(state(tenant: "loja-b", ref: "deepseek/deepseek-v4-flash")).to eq(:closed)
    expect(state(tenant: "loja-a", ref: "openai/gpt-4o-mini")).to eq(:closed)
    expect(state(tenant: "loja-a", ref: "deepseek/deepseek-v4-flash")).to eq(:open)
  end

  it "works on the SQLite backend (durable production path)" do
    sqlite = Insika::Stores::SQLite.new(path: ":memory:")
    durable = Insika::CircuitState.new(store: sqlite)
    3.times { durable.record_failure(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                                     after: BREAKER_AFTER, within: BREAKER_WITHIN, now: t0) }
    expect(durable.state(tenant: nil, ref: "deepseek/deepseek-v4-flash",
                         after: BREAKER_AFTER, within: BREAKER_WITHIN, cooldown: BREAKER_COOLDOWN, now: t0)).to eq(:open)
  ensure
    sqlite&.close
  end

  def c(seconds) = seconds # reader aid: offsets on the t0 epoch
end