# frozen_string_literal: true

require "time"

module Insika
  # WS8 (phase 2): retention — the engine forgets what is old enough to forget.
  # Age-based purge of the CONVERSATION footprint: sessions (and their
  # per-session tool/context traces), terminal tasks (and their checkpoints),
  # customer/tenant memory cells and outcome records. The knob is data, not
  # code: `settings.retention_days` (Integer; nil/0 = OFF — parity, nothing is
  # ever swept by default).
  #
  # Cadence: the Tick calls `run` every pass; an internal DAILY claim (the
  # tick's window idiom — one key, a timestamp, 24 h) makes the actual sweep
  # once a day, so the O(n) scans never ride the 60 s loop. A sweep that
  # crashes propagates to the tick, which logs and keeps ticking.
  class Retention
    SCOPE = "retention"
    KEY = "claim"
    BUDGET_KEY = "budget_claim"
    # the MEMORY TTL's own daily claim. Deliberately NOT the age-based
    # KEY — memory TTLs sweep on their own knob (`memory_ttl_days`), gated by
    # neither retention_days nor the age-based claim (D5).
    MEMORY_TTL_KEY = "memory_ttl_claim"
    WINDOW = 86_400 # one sweep per day, at most

    TERMINAL = %w[completed failed cancelled].freeze

    def initialize(session_store:, task_store:, checkpoint_store:,
                   memory_store:, outcome_store:, tool_trace_store: nil,
                   context_trace_store: nil, outbox_store: nil, shadow_pair_store: nil,
                    settings_store: nil, budget_ledger: nil, funnel_store: nil,
                    followup_store: nil, contact_store: nil, proposal_store: nil,
                    model_visible_trace_store: nil,
                     store:, window: WINDOW, now: nil, harvest_store: nil)
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @memory_store = memory_store
      @outcome_store = outcome_store
      @tool_trace_store = tool_trace_store
      @context_trace_store = context_trace_store
      @model_visible_trace_store = model_visible_trace_store #  ; nil = parity
      @outbox_store = outbox_store
      @shadow_pair_store = shadow_pair_store
      @settings_store = settings_store
      @budget_ledger = budget_ledger # WS2 counter GC; nil = nothing to sweep
      @funnel_store = funnel_store   #  ; nil = nothing to sweep
      @followup_store = followup_store #  ; nil = nothing to sweep
      @contact_store = contact_store   #  ; nil = nothing to sweep
      @proposal_store = proposal_store #  ; nil = nothing to sweep
      @store = store
      @window = window
      @now = now # injectable for specs (a deterministic "today")
      @harvest_store = harvest_store #  ; nil = nothing to sweep
    end

    # the sweep reads the memory store's cells/records (specs seed
    # facts through it).
    attr_reader :memory_store

    # -> { claimed: false } |
    #    { claimed: true, sessions:, tasks:, outcomes:, memory:, deliveries: }.
    # Either shape may carry `budget_cells:` — the budget counter GC is NOT
    # gated by retention_days (see #sweep_budget_cells). Either shape may carry
    # `memory_ttl:` — the   memory TTL sweep, gated by ITS OWN daily
    # claim and knob, never by retention_days (see #sweep_memory_ttl).
    def run
      budget_cells = sweep_budget_cells
      memory_ttl = sweep_memory_ttl
      days = retention_days
      unless days.to_i.positive? && claim_window
        summary = { claimed: false }
        summary[:budget_cells] = budget_cells if budget_cells
        summary[:memory_ttl] = memory_ttl if memory_ttl
        return summary
      end

      cutoff = now - (days.to_i * 86_400)
      summary = { claimed: true, sessions: sweep_sessions(cutoff),
                  tasks: sweep_tasks(cutoff), outcomes: sweep_outcomes(cutoff),
                  memory: @memory_store.prune_older_than(cutoff),
                  deliveries: sweep_outbox(cutoff),
                  pairs: sweep_shadow_pairs(cutoff) }
      summary[:funnel] = sweep_funnel(cutoff) if @funnel_store
      # the follow-up footprint ages out with the rest — records
      # and contact cells under the SAME retention_days gate (nil collaborator
      # = nothing to sweep, base graph parity).
      summary[:followups] = @followup_store.delete_older_than(cutoff) if @followup_store
      summary[:contacts] = @contact_store.delete_older_than(cutoff) if @contact_store
      # proposals are evidence OF a transcript — when the
      # transcript dies, the proposal's excerpt is gone and the pending fact is
      # stale. Pending AND terminal rows age out together; a proposal is
      # re-derivable (D2), so pruning is never data loss. The session MARKERS
      # are never pruned (the store's rule — the marker is the claim).
      summary[:proposals] = @proposal_store.delete_older_than(cutoff) if @proposal_store
      # candidates (pending AND terminal), log rows and
      # snapshots are DERIVED data of transcripts (D11) — when the transcripts
      # die, the candidates' excerpts are gone; they are re-derivable (D2), so
      # pruning is never data loss. The session markers are never pruned.
      summary[:harvest] = @harvest_store.delete_older_than(cutoff) if @harvest_store
      summary[:budget_cells] = budget_cells if budget_cells
      summary[:memory_ttl] = memory_ttl if memory_ttl
      summary
    end

    private

    # The BudgetLedger's expired cells (WS2). Deliberately OUTSIDE the
    # retention_days gate, on its OWN daily claim: those rows are engine
    # bookkeeping whose window already rolled over, not customer content, so a
    # deployment that keeps its conversations forever (retention OFF — the
    # default) must still not grow budget rows forever. -> count | nil (no
    # ledger, or another worker holds today's claim).
    def sweep_budget_cells
      return nil unless @budget_ledger && claim(BUDGET_KEY)

      @budget_ledger.prune(now: now)
    end

    def retention_days
      return nil unless @settings_store

      value = @settings_store.get["retention_days"]
      value.to_s.empty? ? nil : Integer(value)
    rescue ArgumentError, TypeError
      nil # a non-numeric value reads as OFF — never a crash at sweep time
    end

    # the memory TTL sweep — TWO independent expiry clocks under
    # ONE daily claim:
    #   1. per-fact expires_at (prune_expired — past dates physically removed);
    #   2. per-cell TTL by `memory_ttl_days` (age by the cell's updated_at).
    # A fact with an explicit expires_at is EXCLUDED from the age-based pass
    # (the explicit override owns that fact's life). Runs on its OWN claim and
    # knob — a deployment with retention_days off still honors memory TTLs.
    # -> Integer (removed) | nil (no knob, or another worker holds the claim).
    def sweep_memory_ttl
      ttl = memory_ttl_setting
      return nil if ttl.nil?
      return nil unless claim(MEMORY_TTL_KEY)

      removed = @memory_store.prune_expired(now)
      ttl_cutoffs(ttl).each do |scope, cutoff|
        removed += @memory_store.prune_older_than(cutoff, scope: scope)
      end
      removed
    end

    # settings["memory_ttl_days"]: Integer | Hash{ "<tenant>" => days, "*" => days }.
    # nil/empty/blank -> nil (OFF — parity). A non-numeric value -> nil (never
    # a crash at sweep time, the retention_days rescue pattern).
    def memory_ttl_setting
      return nil unless @settings_store

      raw = @settings_store.get["memory_ttl_days"]
      case raw
      when Integer then raw
      when Hash
        map = raw.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = Integer(v.to_s)
        rescue ArgumentError, TypeError
          next
        end
        map.empty? ? nil : map
      end
    end

    # -> [[scope, Time]] — one per existing cell with a resolved TTL. The
    # setting is passed in (one settings-store read per sweep — the caller
    # already resolved it).
    def ttl_cutoffs(setting = memory_ttl_setting)
      return [] unless setting

      @memory_store.cells.filter_map do |cell|
        days = cell_ttl(cell, setting)
        next if days.nil? || days <= 0

        [cell[:scope], now - days * 86_400]
      end
    end

    # Customer cell "memory:acme:c-1" -> map["acme"]; tenant/bare cell
    # "memory:acme" or "memory:c-123" -> map["acme"] / map["c-123"]; fallback
    # map["*"]; an Integer setting -> every cell gets it.
    def cell_ttl(cell, setting)
      return setting if setting.is_a?(Integer)

      key = cell[:tenant] || cell[:customer]
      v = key && setting[key]
      v ||= setting["*"]
      v
    end

    # Sessions untouched past the cutoff, and their per-session traces.
    def sweep_sessions(cutoff)
      removed = 0
      @session_store.each_id.each do |id|
        session = @session_store.find(id)
        next unless session && session.updated_at && session.updated_at < cutoff.iso8601

        @tool_trace_store&.clear(id)
        @context_trace_store&.clear(id)
        @session_store.delete(id)
        removed += 1
      end
      removed
    end

    # TERMINAL tasks untouched past the cutoff, and their checkpoints. A
    # non-terminal task (queued/running) is never touched here — the Recovery
    # sweep owns those lives. the model-visible traces are
    # transcripts — they die next to their checkpoints.
    def sweep_tasks(cutoff)
      removed = 0
      @task_store.each_id.each do |id|
        task = @task_store.find(id)
        next unless task && TERMINAL.include?(task.status.to_s)
        next unless task.updated_at && task.updated_at < cutoff.iso8601

        @checkpoint_store.purge(id)
        @model_visible_trace_store&.purge(id)
        @task_store.delete(id)
        removed += 1
      end
      removed
    end

    def sweep_outcomes(cutoff)
      @outcome_store ? @outcome_store.delete_older_than(cutoff) : 0
    end

    # The delivered/failed outbox records past the cutoff. Their `payload` is
    # the answer the customer received — conversation content, so it ages out
    # with the rest of the footprint instead of living in the store forever.
    def sweep_outbox(cutoff)
      @outbox_store ? @outbox_store.delete_older_than(cutoff) : 0
    end

    # Shadow pairs  past the cutoff, TERMINAL statuses only
    # (judged/incomplete) — an open/complete pair older than the window is
    # still someone's unjudged evidence, exactly like the outbox's rule.
    def sweep_shadow_pairs(cutoff)
      @shadow_pair_store ? @shadow_pair_store.delete_older_than(cutoff) : 0
    end

    # the funnel DAY CELLS die with the outcomes they fold — same
    # retention_days gate, same daily claim. Cursors/baselines live while their
    # agent does. nil collaborator = nothing to sweep (base graph, parity).
    def sweep_funnel(cutoff)
      @funnel_store.delete_older_than(cutoff)
    end

    def claim_window = claim(KEY)

    # The daily claim: one key, a timestamp, a 24 h window — the tick's
    # claim_window idiom (a key per day would be a slow leak; the window is
    # long enough that the store never grows). One key per SWEEP (the age-based
    # one, the budget GC): they gate on different knobs, so a single shared key
    # would let whichever ran first starve the other for a day.
    def claim(key)
      now_time = now
      @store.transaction do
        current = @store.get(SCOPE, key)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil
        end
        if last.nil? || (now_time - last) >= @window
          @store.set(SCOPE, key, { "claimed_at" => now_time.iso8601 })
          true
        else
          false
        end
      end
    end

    def now = @now || Time.now.utc
  end
end
