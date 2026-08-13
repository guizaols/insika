# frozen_string_literal: true

module Insika
  # Fixed-window spend counters for BUDGETS (WS2): the accounting layer the
  # edge middleware rolls against. One scope, cells keyed
  # "tenant:agent:window:calendar-bucket":
  #
  #   · DAILY    — the UTC calendar day (epoch/86400 IS midnight-aligned).
  #   · MONTHLY  — (year * 12 + month) of the UTC calendar month: a budget month
  #                is the CALENDAR month, however many days long it is (a fixed
  #                N-day window drifts its bucket start across month lengths).
  #                UTC like the daily, so both rollovers agree on any host.
  #
  # Built on the UsageLedger vocabulary (tenant/agent instead of kind/id) but
  # on the store directly, with the increment riding `@store.transaction` — the
  # exact read-modify-write discipline WS2's enforcement will build on. Two
  # processes (or two SQLite handles) racing the same cell serialize on
  # BEGIN IMMEDIATE: no lost update. No enforcement here — the middleware is
  # WS2; this file is only correct accounting.
  #
  # Growth is bounded on the hot path AND swept: each `add` deletes the (id)'s
  # previous day and previous month cell (an ACTIVE scope holds at most 4 keys),
  # and `prune` — the daily sweep on the tick — drops everything else: the cells
  # of an id that went idle for more than one window and the alert flags, which
  # the hot path never collects.
  class BudgetLedger
    SCOPE = "budget_counters"
    ALERT_SCOPE = "budget_alerts"
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

    # Seconds until the window's bucket rolls over (the retry_after the
    # enforcement quotes when a hard budget refuses a turn). Both windows are
    # UTC-aligned (the daily via the epoch, the monthly via UTC components) so a
    # non-UTC host never quotes a negative or local-midnight reset.
    def reset_in(window, now: Time.now)
      case window
      when :daily then DAY - (now.to_i % DAY)
      when :monthly then (next_utc_month_start(now) - now).to_i
      end
    end

    # "1× per window" alert markers (the soft enforcement's event): a flag per
    # (id, window, level, bucket) so a budget that stays over the threshold
    # cannot spam one event per turn. `level:` separates DISTINCT triggers in
    # the same window (WS2): the `alert_at` crossing and the real soft-cap
    # crossing each warn once — the cap event must not be swallowed by the
    # 80% marker having fired earlier. Marked/read in the same transaction
    # discipline. -> bool: had the window already been marked?
    def mark_alert(tenant:, agent:, window:, level: nil, now: Time.now)
      id = cell_id(tenant, agent)
      flag = alert_key(id, window, now, level)
      @store.transaction do
        # `next`, NOT `return`: a non-local return from inside the block skips
        # the store's COMMIT and leaks the BEGIN IMMEDIATE open — the 2nd turn
        # over a threshold then locks the whole backend (WS2).
        next true unless @store.get(ALERT_SCOPE, flag).nil?

        @store.set(ALERT_SCOPE, flag, 1)
        false
      end
    end

    def alerted?(tenant:, agent:, window:, level: nil, now: Time.now)
      !@store.get(ALERT_SCOPE, alert_key(cell_id(tenant, agent), window, now, level)).nil?
    end

    # The GC of both scopes: drops every cell whose window is not the CURRENT
    # one. `add`'s two deletes only reach the IMMEDIATELY previous day/month, so
    # a scope that goes idle for two days leaves its counter behind forever, and
    # the alert flags were never collected at all — unbounded row growth the WS8
    # retention sweep does not reach (that one is age-based over CONTENT; these
    # are counters with no timestamp). Every key of both scopes ENDS in its
    # bucket, so one rule sweeps both. -> count of cells removed.
    def prune(now: Time.now)
      day = daily_bucket(now)
      month = month_bucket(now)
      @store.transaction do
        [SCOPE, ALERT_SCOPE].sum do |scope|
          stale = @store.list(scope).select { |k| past?(k.rpartition(":").last.to_i, day, month) }
          stale.each { |k| @store.delete(scope, k) }
          stale.size
        end
      end
    end

    private

    # No tenant (single_tenant default) is a LITERAL "platform" cell, never a
    # null-key collision with some other scope.
    def cell_id(tenant, agent)
      [tenant || "platform", agent].join(":")
    end

    # Is that bucket a window STRICTLY BEHIND the live one? The two kinds of
    # bucket cannot collide — an epoch-day is a multiple of 86_400 (~1.7e9), a
    # calendar month is year*12+month (~24e3) — so the magnitude tells them
    # apart. STRICTLY behind, never "not the current one": a host whose clock
    # runs minutes ahead writes tomorrow's cell around midnight, and a sweeper
    # that deleted it would hand that tenant a fresh day of budget.
    def past?(bucket, day, month)
      bucket >= DAY ? bucket < day : bucket.positive? && bucket < month
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

    # the UTC calendar month as one integer (2026-08 -> 24296). UTC, not local:
    # the month boundary must agree with the daily epoch-day boundary on a
    # non-UTC host (WS2), or the cap resets at a different moment than the day.
    def month_bucket(now)
      u = now.utc
      u.year * 12 + u.month
    end

    # Midnight UTC of the 1st of the window's NEXT month — December-safe
    # (Time.utc(y, 13, 1) raises; y+1/1 is the calendar answer).
    def next_utc_month_start(now)
      u = now.utc
      u.month == 12 ? Time.utc(u.year + 1, 1, 1) : Time.utc(u.year, u.month + 1, 1)
    end

    def key(id, bucket)
      "#{id}:#{bucket}"
    end

    # One alert flag per (id, window, level, calendar bucket): daily cells are
    # keyed by day, monthly by (year*12+month) — a flag dies with its window.
    def alert_key(id, window, now, level = nil)
      bucket = window == :monthly ? month_bucket(now) : daily_bucket(now)
      level ? "#{id}:#{window}:#{level}:#{bucket}" : "#{id}:#{window}:#{bucket}"
    end
  end
end