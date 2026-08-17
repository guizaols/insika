# frozen_string_literal: true

require "time"
require "securerandom"

module Insika
  # RFC-0032 C4: the tick-driven fold of WS7 outcome records into the
  # pack-declared stages (RFC-0019's cadence, RFC §4.2). One pass per claim
  # window; the fold is idempotent across crashes via the per-pair {at, ids}
  # cursor (D3) and per-pair transactions. Pairs whose declaration is absent or
  # malformed are skipped (D8), as are outcome kinds the declaration does not
  # map — the funnel shows the hole (RFC §2). Nothing else: no attribution
  # (D4), no stage vocabulary of its own (D1).
  class FunnelFold
    SCOPE = "funnel_fold"
    KEY = "claim"
    DEFAULT_WINDOW = 300 # seconds; one folding worker per window

    def initialize(outcome_store:, funnel_store:, profiles:, store:,
                   window: DEFAULT_WINDOW, now: nil)
      @outcome_store = outcome_store
      @funnel_store = funnel_store
      @profiles = profiles
      @store = store
      @window = window
      @now = now
    end

    # One pass. -> { claimed: true, folded: Integer, skipped: Integer, pairs: Integer }
    #             | { claimed: false }  (another worker holds the window — the
    #               retention.rb:74 shape, so the tick summary reads uniformly)
    def run
      return { claimed: false } unless claim

      folded = 0
      skipped = 0
      pairs = 0
      # The pairs come from the OUTCOME keys (prefix scan, no record reads);
      # each pair's records are read by `for_pair`, so a pair without a
      # declaration is never even read (a full `all` would read every record
      # of every pair — the O(n) the key shape is there to avoid).
      @outcome_store.pairs.each do |pair|
        begin
          declaration = declaration_for(pair[:agent])
          next unless declaration

          folded += fold_pair(tenant: pair[:tenant], agent: pair[:agent],
                              declaration: declaration, skipped: -> { skipped += 1 })
          pairs += 1
        rescue StandardError
          # a broken pair must not hold every other store's funnel hostage —
          # its own transaction already rolled back; the pass keeps folding.
          next
        end
      end
      { claimed: true, folded: folded, skipped: skipped, pairs: pairs }
    end

    # From scratch (E1's "recompute matches the incremental fold", and the
    # repair path for backfilled outcomes): wipes the pair's day cells and
    # rebuilds them from every outcome record. `tenant:` takes the store's
    # spellings alike (nil/""/"platform" = the no-tenant pair) — `for_pair` and
    # `delete_days` normalize at their own key boundaries, so no tenant is
    # ever mixed with another (a "platform" recompute never folds "acme"'s
    # records). -> folded count.
    def recompute(tenant:, agent:, declaration:)
      @funnel_store.delete_days(tenant: tenant, agent: agent)
      fold_pair(tenant: tenant, agent: agent, declaration: declaration, full: true)
    end

    private

    # -> FunnelDeclaration | nil — absent or malformed declarations read as
    # "nothing to fold" (D8); never raises.
    def declaration_for(agent)
      profile = @profiles.fetch(agent)
      return nil unless profile

      Insika::FunnelDeclaration.parse(profile.funnel)
    end

    # The fold for one pair: cursor-filtered, ONE transaction (all adds + the
    # cursor write — D3: a crash leaves either the old or the new state, never
    # a half-fold). `full: true` (recompute) ignores the cursor — every record
    # folds and the cursor rewrites from the newest. Records are read by key
    # prefix, optionally skipping the keys older than the cursor's day without
    # reading them. -> folded count.
    def fold_pair(tenant:, agent:, declaration:, records: nil, skipped: nil, full: false)
      cursor = @funnel_store.cursor(tenant: tenant, agent: agent)
      # The cursor's DAY is the prefix bound: records on that day may still be
      # newer than the cursor (boundary handling below); anything older is
      # already folded. `full` reads the whole pair.
      records ||= @outcome_store.for_pair(tenant: tenant, agent: agent,
                                          since_date: full ? nil : cursor["at"]&.[](0, 10))
      new_records = records.select { |r| full || new_record?(r, cursor) }
                          .sort_by { |r| [r.at.to_s, r.id] }
      return 0 if new_records.empty? && !full
      if new_records.empty?
        # recompute of an emptied pair: nothing to fold, but the stale cursor
        # must not outlive its records (a later backfill would be invisible).
        @funnel_store.set_cursor(tenant: tenant, agent: agent, at: nil, ids: [])
        return 0
      end

      folded = 0
      # Grouped by DAY (the cell key), never by the full timestamp: N events on
      # one day must be ONE read-modify-write of the day cell, not N.
      counts_by_day = Hash.new { |h, k| h[k] = Hash.new(0) }
      at_by_day = {}
      newest_at = full ? nil : cursor["at"]
      ids_at_newest = []

      new_records.each do |record|
        # The cursor advances over SKIPPED records too (they are not new any
        # more): a pair whose integration only emits unmapped kinds would
        # otherwise re-read the same records every window forever.
        if newest_at.nil? || record.at.to_s > newest_at.to_s
          newest_at = record.at.to_s
          ids_at_newest = [record.id]
        elsif record.at.to_s == newest_at.to_s
          ids_at_newest << record.id
        end

        index = declaration.index_of(declaration.advance_on[record.outcome])
        if index.nil?
          skipped&.call
          next
        end

        day = record.at.to_s[0, 10] # the record's at is always UTC ISO8601
        declaration.stages[0..index].each { |stage| counts_by_day[day][stage] += 1 }
        at_by_day[day] ||= record.at.to_s
        folded += 1
      end

      @store.transaction do
        counts_by_day.each do |day, counts|
          @funnel_store.add(tenant: tenant, agent: agent, at: at_by_day[day], counts: counts)
        end
        @funnel_store.set_cursor(tenant: tenant, agent: agent,
                                 at: newest_at, ids: ids_at_newest)
      end
      folded
    end

    # `at > cursor.at` or boundary-equal and not already folded (D3). The at
    # field is ISO8601 UTC, so the comparison is lexicographic; a record with
    # `at` older than the cursor (a backfill) is missed incrementally —
    # `recompute` is the repair path.
    def new_record?(record, cursor)
      at = cursor["at"]
      return true if at.nil?
      return true if record.at.to_s > at.to_s

      record.at.to_s == at.to_s && !cursor["ids"].include?(record.id)
    end

    # The claim window (tick.rb:93's idiom — read-check-write on one key inside
    # a transaction): the scan is O(outcome records), fine at 288 passes/day,
    # but it does not ride every 60 s tick.
    def claim
      now_time = @now || Time.now.utc
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil # a corrupted claim is not a claim — take the window
        end
        if last.nil? || (now_time - last) >= @window
          @store.set(SCOPE, KEY, { "claimed_at" => now_time.iso8601 })
          true
        else
          false
        end
      end
    end
  end
end
