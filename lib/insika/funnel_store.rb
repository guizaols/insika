# frozen_string_literal: true

require "time"

module Insika
  # the durable aggregates of the OUTCOME FUNNEL — per-day stage
  # counts (the fold's cells), the fold cursor and the baseline snapshot.
  # A dumb domain store: it holds no outcome_store and never folds (C4 owns the
  # transformation), and it is recomputable by construction — the OutcomeStore
  # stays the source of truth.
  #
  # Key shapes (string keys, Store-contract JSON):
  #   "funnel"           "acme:store-support:2026-08-14"  -> { "greeted" => 41, "paid" => 3 }
  #   "funnel_cursor"    "acme:store-support"             -> { "at" => ISO8601 | nil, "ids" => [uuid, …] }
  #   "funnel_baseline"  "acme:store-support"             -> { from/to/stages/primary/…/frozen_at }
  #
  # The no-tenant case is the literal "platform" (the outcome KEY's rule), so
  # funnel and outcome keys share the same tenant segment and the purge prefix
  # scan is the same string. A record's `tenant` field is `tenant.to_s` — "" for
  # a single-tenant write — so every key-builder normalizes a blank tenant to
  # "platform" HERE (one place), or a single-tenant fold lands in an ""-prefixed
  # cell that purge("platform") never removes.
  class FunnelStore
    SCOPE          = "funnel"          # day cells
    CURSOR_SCOPE   = "funnel_cursor"   # per (tenant, agent)
    BASELINE_SCOPE = "funnel_baseline" # per (tenant, agent)

    def initialize(store:)
      @store = store
    end

    # Cumulative increment (D2): `counts` is the fold's { stage => 1 } hash for
    # the reached prefix stages[0..index] — the STORE stays free of the
    # declaration (D1), it only accumulates. Bumped in ONE transaction.
    # -> { stage => count } the NEW day counts (string keys, declared order).
    def add(tenant:, agent:, at:, counts:)
      id = pair_id(tenant, agent)
      day_key = day_segment(at)
      @store.transaction do
        cell = @store.get(SCOPE, "#{id}:#{day_key}") || {}
        counts.each { |stage, n| cell[stage.to_s] = cell[stage.to_s].to_i + n }
        @store.set(SCOPE, "#{id}:#{day_key}", cell)
        cell
      end
    end

    # -> { stage => count } | {} — one day's cell ("YYYY-MM-DD").
    def day(tenant:, agent:, day:)
      @store.get(SCOPE, "#{pair_id(tenant, agent)}:#{day}") || {}
    end

    # -> { "YYYY-MM-DD" => { stage => count } } sorted ascending, bounded by
    # ISO-date strings from:/to: (inclusive). Empty hash when none.
    def days(tenant:, agent:, from: nil, to: nil)
      prefix = "#{pair_id(tenant, agent)}:"
      @store.list(SCOPE).select { |k| k.start_with?(prefix) }.each_with_object({}) do |k, acc|
        day = k.delete_prefix(prefix)
        next unless within?(day, from, to)

        acc[day] = @store.get(SCOPE, k)
      end.sort.to_h
    end

    # The fold cursor of the pair. -> { "at" => String | nil, "ids" => [String] }
    def cursor(tenant:, agent:)
      record = @store.get(CURSOR_SCOPE, pair_id(tenant, agent))
      { "at" => record && record["at"], "ids" => Array(record && record["ids"]) }
    end

    def set_cursor(tenant:, agent:, at:, ids:)
      @store.set(CURSOR_SCOPE, pair_id(tenant, agent), { "at" => at, "ids" => Array(ids) })
    end

    # -> Hash | nil — the current baseline record (D5), read back verbatim.
    def baseline(tenant:, agent:)
      @store.get(BASELINE_SCOPE, pair_id(tenant, agent))
    end

    # Overwrites (D5 — one current snapshot per pair, no history).
    def set_baseline(tenant:, agent:, record:)
      @store.set(BASELINE_SCOPE, pair_id(tenant, agent), record)
    end

    # Purge one tenant: its day cells, cursors and baselines (DeleteTenantData,
    # WS8 — the tenant is the FIRST key segment, so a prefix scan; the key IS
    # the isolation). -> count removed.
    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      [SCOPE, CURSOR_SCOPE, BASELINE_SCOPE].sum do |scope|
        keys = @store.list(scope).select { |k| k.start_with?(prefix) }
        keys.each { |k| @store.delete(scope, k) }
        keys.size
      end
    end

    # Age-based prune of DAY CELLS ONLY (retention, WS8 — outcomes and their
    # fold die together). The day is the key's last segment ("YYYY-MM-DD",
    # lexicographic). Cursors/baselines are tiny and live while their agent
    # does. -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.strftime("%Y-%m-%d")
      removed = 0
      @store.list(SCOPE).each do |k|
        day = k.rpartition(":").last
        next unless day < cutoff

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    # wipes ONE pair's day cells — the recompute repair path (the
    # fold rebuilds them from the outcome store, so it must start from zero,
    # never sum on top). Same tenant normalization as every other key builder
    # (`""`/nil/"platform" all reach the "platform" segment). -> count removed.
    def delete_days(tenant:, agent:)
      prefix = "#{pair_id(tenant, agent)}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    # The pairs that have any day cell — the Studio's derived drill (D7).
    # -> [{ tenant: String | nil, agent: String }]
    def pairs
      @store.list(SCOPE).map { |k| pair_of(k) }.uniq
    end

    private

    def pair_id(tenant, agent)
      "#{tenant_id(tenant)}:#{agent}"
    end

    # The literal "platform" for a blank tenant — the outcome KEY's rule
    # (outcome_store.rb's key), normalized in ONE place.
    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    def day_segment(at)
      t = at.is_a?(Time) ? at : Time.parse(at.to_s)
      t.utc.strftime("%Y-%m-%d")
    end

    # Tolerant like the series reads: a malformed bound (not an ISO date) reads
    # as unbounded — never a crash, never a silent empty window.
    DATE_RE = /\A\d{4}-\d{2}-\d{2}\z/

    def within?(day, from, to)
      lo = DATE_RE.match?(from.to_s) ? from.to_s : nil
      hi = DATE_RE.match?(to.to_s) ? to.to_s : nil
      (lo.nil? || day >= lo) && (hi.nil? || day <= hi)
    end

    def pair_of(key)
      tenant, agent, = key.split(":", 3)
      { tenant: tenant == "platform" ? nil : tenant, agent: agent }
    end
  end
end
