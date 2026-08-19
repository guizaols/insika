# frozen_string_literal: true

require "time"

module Insika
  # the trigger — finds due sessions and distills them. It
  # spawns a worker fiber (supervisor child, `Tick#start` shape) whose loop
  # claims a window and runs the distillation for due sessions ON the worker
  # fiber — off the tick's critical path and off every customer turn's path.
  # The scan uses the engine default `idle_hours` (6) as the LOWER BOUND; the
  # per-agent value is re-checked inside RunDistillation (a pack that wants
  # 12 h is never distilled at 6).
  #
  # D2 — no queue: the per-session marker is the claim. A crash mid-pass
  # leaves markers unwritten and the next boot re-scans; the dedup ledger
  # filters duplicates. Two workers racing the same session both run, and the
  # ledger still filters.
  class DistillEngine
    SCOPE = "distill"
    KEY = "claim"
    DEFAULT_WINDOW = 300 # seconds — the O(n) scan never rides the 60 s loop
    DEFAULT_IDLE_HOURS = 6
    DEFAULT_MIN_MESSAGES = 3

    def initialize(store:, proposal_store:, session_store:, runner:, profiles: nil,
                   logger: nil, window: DEFAULT_WINDOW,
                   idle_hours: DEFAULT_IDLE_HOURS, sleeper: nil)
      @store = store
      @proposal_store = proposal_store
      @session_store = session_store
      @runner = runner
      @profiles = profiles # profile source; nil/empty = nothing distills (parity)
      @logger = logger
      @window = window.to_i
      @idle_hours = idle_hours.to_i
      @sleeper = sleeper || method(:default_sleep)
    end

    # The supervisor child (tick.rb:69-83's shape): loop { sleeper(window);
    # run_once rescue log }. Returns false when idle_hours <= 0 (the engine
    # default OFF switch — parity) OR when no profile declares a distillation
    # (a scan with nothing to distill would re-read every session record every
    # window forever — each pass skips at the command, writes no marker, and
    # repeats).
    def start(parent:)
      return false unless distillable?
      return true if @task&.running?

      @task = parent.async do |t|
        t.annotate("insika-distill")
        loop do
          @sleeper.call(@window)
          run_once
        rescue StandardError => e
          log(:warn, "distill pass failed: #{e.class}: #{e.message}")
        end
      end
      true
    end

    # One pass. -> { claimed: false } | { claimed: true, distilled: N,
    #   skipped: N, errors: N }
    def run_once
      return { claimed: false } unless distillable?
      return { claimed: false } unless claim_window

      distilled = 0
      skipped = 0
      errors = 0
      due_sessions.each do |session|
        begin
          outcome = @runner.call(Insika::Command.build(:run_distillation,
                                                       { session_id: session.id }))
          if outcome[:distilled]
            distilled += 1
          else
            skipped += 1
          end
        rescue StandardError
          # a broken session must not hold the pass; the marker discipline
          # keeps it re-runnable.
          errors += 1
        end
      end
      { claimed: true, distilled: distilled, skipped: skipped, errors: errors }
    end

    private

    # The engine is inert unless the switch is on (idle_hours > 0) AND at
    # least one profile declares an enabled distillation — without one, a pass
    # would re-read every session record every window forever (each due
    # session skips at the command, writes no marker, and repeats).
    def distillable?
      return false if @idle_hours <= 0
      return false if @profiles.nil?

      profiles_list.any? do |p|
        config = p.respond_to?(:distill) ? p.distill : nil
        config && Coercion.truthy?(config["enabled"])
      end
    end

    def profiles_list
      return @profiles.values if @profiles.respond_to?(:values)

      @profiles.respond_to?(:all) ? @profiles.all : []
    end

    # Sessions whose `vars["customer"]` and `vars["agent"]` are present, older
    # than the engine default idle window, with enough messages, and not yet
    # distilled. Oldest first.
    def due_sessions
      cutoff = Time.now.utc - @idle_hours * 3600
      ids = []
      @session_store.each_id do |id|
        session = @session_store.find(id)
        next unless session
        next if Coercion.blank?(session.vars["customer"])
        next if Coercion.blank?(session.vars["agent"])
        next unless aged?(session.updated_at, cutoff)
        next if session.messages.size < DEFAULT_MIN_MESSAGES
        next if @proposal_store.distilled?(id)

        ids << session
      end
      ids.sort_by { |s| s.updated_at.to_s }
    end

    def aged?(updated_at, cutoff)
      return false if Coercion.blank?(updated_at)

      Time.iso8601(updated_at.to_s) <= cutoff
    rescue ArgumentError
      false
    end

    # One worker per window across N workers — the tick's claim idiom
    # (one key, a timestamp, a window).
    def claim_window
      now = Time.now.utc
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil # a corrupted claim is not a claim — take the window
        end
        if last.nil? || (now - last) >= @window
          @store.set(SCOPE, KEY, { "claimed_at" => now.iso8601 })
          true
        else
          false
        end
      end
    end

    def default_sleep(seconds)
      task = defined?(Async::Task) ? Async::Task.current? : nil
      task ? task.sleep(seconds) : sleep(seconds)
    end

    def log(level, message)
      @logger&.public_send(level, "[distill] #{message}")
    rescue StandardError
      nil
    end
  end
end
