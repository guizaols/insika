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
    WINDOW = 86_400 # one sweep per day, at most

    TERMINAL = %w[completed failed cancelled].freeze

    def initialize(session_store:, task_store:, checkpoint_store:,
                   memory_store:, outcome_store:, tool_trace_store: nil,
                   context_trace_store: nil, settings_store: nil, store:,
                   window: WINDOW, now: nil)
      @session_store = session_store
      @task_store = task_store
      @checkpoint_store = checkpoint_store
      @memory_store = memory_store
      @outcome_store = outcome_store
      @tool_trace_store = tool_trace_store
      @context_trace_store = context_trace_store
      @settings_store = settings_store
      @store = store
      @window = window
      @now = now # injectable for specs (a deterministic "today")
    end

    # -> { claimed: false } | { claimed: true, sessions:, tasks:, outcomes:, memory: }.
    def run
      days = retention_days
      return { claimed: false } unless days.to_i.positive? && claim_window

      cutoff = now - (days.to_i * 86_400)
      summary = { claimed: true, sessions: sweep_sessions(cutoff),
                  tasks: sweep_tasks(cutoff), outcomes: sweep_outcomes(cutoff),
                  memory: @memory_store.prune_older_than(cutoff) }
      summary
    end

    private

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

    # The daily claim: one key, a timestamp, a 24 h window — the tick's
    # claim_window idiom (a key per day would be a slow leak; the window is
    # long enough that the store never grows).
    def claim_window
      now_time = now
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil
        end
        if last.nil? || (now_time - last) >= @window
          @store.set(SCOPE, KEY, { "claimed_at" => now_time.iso8601 })
          true
        else
          false
        end
      end
    end

    def now = @now || Time.now.utc
  end
end
