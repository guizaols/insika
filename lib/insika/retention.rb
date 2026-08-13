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
    WINDOW = 86_400 # one sweep per day, at most

    TERMINAL = %w[completed failed cancelled].freeze

    def initialize(session_store:, task_store:, checkpoint_store:,
                   memory_store:, outcome_store:, tool_trace_store: nil,
                   context_trace_store: nil, outbox_store: nil, settings_store: nil,
                   budget_ledger: nil, store:, window: WINDOW, now: nil)
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @memory_store = memory_store
      @outcome_store = outcome_store
      @tool_trace_store = tool_trace_store
      @context_trace_store = context_trace_store
      @outbox_store = outbox_store
      @settings_store = settings_store
      @budget_ledger = budget_ledger # WS2 counter GC; nil = nothing to sweep
      @store = store
      @window = window
      @now = now # injectable for specs (a deterministic "today")
    end

    # -> { claimed: false } |
    #    { claimed: true, sessions:, tasks:, outcomes:, memory:, deliveries: }.
    # Either shape may carry `budget_cells:` — the budget counter GC is NOT
    # gated by retention_days (see #sweep_budget_cells).
    def run
      budget_cells = sweep_budget_cells
      days = retention_days
      unless days.to_i.positive? && claim_window
        return budget_cells.nil? ? { claimed: false } : { claimed: false, budget_cells: budget_cells }
      end

      cutoff = now - (days.to_i * 86_400)
      summary = { claimed: true, sessions: sweep_sessions(cutoff),
                  tasks: sweep_tasks(cutoff), outcomes: sweep_outcomes(cutoff),
                  memory: @memory_store.prune_older_than(cutoff),
                  deliveries: sweep_outbox(cutoff) }
      summary[:budget_cells] = budget_cells if budget_cells
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
    # sweep owns those lives.
    def sweep_tasks(cutoff)
      removed = 0
      @task_store.each_id.each do |id|
        task = @task_store.find(id)
        next unless task && TERMINAL.include?(task.status.to_s)
        next unless task.updated_at && task.updated_at < cutoff.iso8601

        @checkpoint_store.purge(id)
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
