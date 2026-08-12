# frozen_string_literal: true

module Insika
  # Fixed-window spend counters for BUDGETS (WS2): the accounting layer the
  # edge middleware rolls against. One scope, cells keyed
  # "tenant:agent:window:calendar-bucket":
  #
  #   · DAILY    — the UTC calendar day (epoch/86400 IS midnight-aligned).
  #   · MONTHLY  — (year * 12 + month): a budget month is the CALENDAR month,
  #                however many days long it is (a fixed N-day window drifts
  #                its bucket start across month lengths).
  #
  # Built on the UsageLedger vocabulary (tenant/agent instead of kind/id) but
  # on the store directly, with the increment riding `@store.transaction` — the
  # exact read-modify-write discipline WS2's enforcement will build on. Two
  # processes (or two SQLite handles) racing the same cell serialize on
  # BEGIN IMMEDIATE: no lost update. No enforcement here — the middleware is
  # WS2; this file is only correct accounting.
  #
  # Growth is bounded like UsageLedger: each `add` deletes the (id)'s previous
  # day AND previous month cell, so an active scope holds at most 4 keys and an
  # idle one converges to 2.
  class BudgetLedger
    SCOPE = "budget_counters"
    DAY = 86_400

    def initialize(store:)
      @store = store
    end

    # Adds `by` across both windows; -> { daily:, monthly: } the NEW totals
    # for (tenant, agent). Atomic per call: one transaction, both bumps.
    def add(tenant:, agent:, by:, now: Time.now)
      id = cell_id(tenant, agent)
      @store.transaction do
        daily = bump(id, daily_bucket(now), by)
        monthly = bump(id, month_bucket(now), by)
        @store.delete(SCOPE, key(id, daily_bucket(now - DAY)))   # previous day cell
        @store.delete(SCOPE, key(id, month_bucket(now) - 1))     # previous calendar month cell
        { daily: daily, monthly: monthly }
      end
    end

    # -> { daily:, monthly: } current totals for (tenant, agent). Purely
    # read; an expired window reads as 0 (rolls over at the boundary).
    def current(tenant:, agent:, now: Time.now)
      id = cell_id(tenant, agent)
      { daily: @store.get(SCOPE, key(id, daily_bucket(now))).to_i,
        monthly: @store.get(SCOPE, key(id, month_bucket(now))).to_i }
    end

    private

    # No tenant (single_tenant default) is a LITERAL "platform" cell, never a
    # null-key collision with some other scope.
    def cell_id(tenant, agent)
      [tenant || "platform", agent].join(":")
    end

    def bump(id, bucket, by)
      total = @store.get(SCOPE, key(id, bucket)).to_i + by
      @store.set(SCOPE, key(id, bucket), total)
      total
    end

    # the UTC calendar day's start (epoch is aligned to midnight UTC).
    def daily_bucket(now)
      (now.to_i / DAY) * DAY
    end

    # the calendar month as one integer (2026-08 -> 24296).
    def month_bucket(now)
      now.year * 12 + now.month
    end

    def key(id, bucket)
      "#{id}:#{bucket}"
    end
  end
end