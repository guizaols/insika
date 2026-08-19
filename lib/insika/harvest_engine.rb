# frozen_string_literal: true

require "time"

module Insika
  # the trigger — finds due sessions and mines them. It
  # spawns a worker fiber (supervisor child, `Tick#start` shape) whose loop
  # claims a window and runs ONE due session's harvest ON the worker fiber —
  # off the tick's critical path and off every customer turn's path (D2: the
  # mining model call never blocks a customer turn).
  #
  # The scan uses the engine default `idle_hours` (24) as the LOWER BOUND; the
  # per-agent value is re-checked inside RunHarvest. The loop-stop (the
  # H-harvest kill) is the profile's `enabled: false` — the engine only
  # respects data (D4).
  class HarvestEngine
    SCOPE = "harvest_engine"
    KEY = "claim"
    DEFAULT_WINDOW = 300 # seconds — the O(n) scan never rides the 60 s loop
    DEFAULT_IDLE_HOURS = 24
    DEFAULT_MIN_MESSAGES = 3

    def initialize(store:, harvest_store:, session_store:, runner:,
                   profiles: nil, logger: nil, window: DEFAULT_WINDOW,
                   idle_hours: DEFAULT_IDLE_HOURS, sleeper: nil)
      @store = store
      @harvest_store = harvest_store
      @session_store = session_store
      @runner = runner
      @profiles = profiles # profile source; nil/empty = nothing mines (parity)
      @logger = logger
      @window = window.to_i
      @idle_hours = idle_hours.to_i
      @sleeper = sleeper || method(:default_sleep)
    end

    # The deployment root swaps in its own runner (the bus instance carrying
    # the negative list + the settings-backed miner factory); the base graph's
    # inert one keeps the loop honest until then.
    attr_accessor :runner

    # The supervisor child (tick.rb:69-83's shape). Returns false when
    # idle_hours <= 0 (the engine default OFF switch — parity) OR when no
    # profile declares an enabled harvest (a scan with nothing to mine would
    # re-read every session record every window forever).
    def start(parent:)
      return false unless harvestable?

      @task = parent.async do |t|
        t.annotate("insika-harvest")
        loop do
          @sleeper.call(@window)
          run_once
        rescue StandardError => e
          log(:warn, "harvest pass failed: #{e.class}: #{e.message}")
        end
      end
      true
    end

    # One pass. -> { claimed: false } | { claimed: true, mined: N,
    #   skipped: N, errors: N }
    def run_once
      return { claimed: false } unless harvestable?
      return { claimed: false } unless claim_window

      session = due_sessions.first # one model call per pass; the window paces
      return { claimed: true, mined: 0, skipped: 0, errors: 0 } if session.nil?

      begin
        outcome = @runner.call(Insika::Command.build(:run_harvest,
                                                     { agent: session[:agent],
                                                       session_ids: [session[:id]] }))
        if outcome[:mined]
          { claimed: true, mined: 1, skipped: 0, errors: 0 }
        else
          { claimed: true, mined: 0, skipped: 1, errors: 0 }
        end
      rescue StandardError
        # a broken session must not hold the pass; the marker discipline
        # keeps it re-runnable.
        { claimed: true, mined: 0, skipped: 0, errors: 1 }
      end
    end

    private

    # The engine is inert unless the switch is on (idle_hours > 0) AND at
    # least one profile declares an enabled harvest (the loop-stop: the
    # H-harvest kill is `enabled: false`). The grounding matcher is a
    # per-session pre-filter (D3), never an engine-wide switch.
    def harvestable?
      return false if @idle_hours <= 0
      return false if @profiles.nil?

      profiles_list.any? do |p|
        config = p.respond_to?(:harvest) ? p.harvest : nil
        config && Coercion.truthy?(config["enabled"])
      end
    end

    def matcher_configured?(profile)
      grounding = Grounding.parse(profile.grounding)
      grounding && grounding.matcher.sku?
    rescue StandardError
      false
    end

    def profiles_list
      return @profiles.values if @profiles.respond_to?(:values)

      @profiles.respond_to?(:all) ? @profiles.all : []
    end

    # Sessions with `vars["agent"]`, idle past the PROFILE's own bounds, with
    # enough messages, not yet mined, whose agent declares harvest.enabled + a
    # matcher. Oldest first. One session per pass is enough (each is a model
    # call).
    #
    # The scan reads the per-agent idle_hours/min_messages (the engine
    # defaults only when the pack does not declare them): a session the pack's
    # bounds reject is NOT elected, so it can never sit at the head of the
    # queue — RunHarvest would skip it, write no marker, and it would be
    # "the oldest" forever, starving every later session (the review fix).
    def due_sessions
      due = []
      @session_store.each_id do |id|
        session = @session_store.find(id)
        next unless session
        next if @harvest_store.mined?(id)
        next if Coercion.blank?(session.vars["agent"])

        profile = @profiles[session.vars["agent"].to_s]
        next unless profile
        next unless harvest_declared?(profile)

        config = profile.respond_to?(:harvest) ? profile.harvest : nil
        idle_hours = config&.key?("idle_hours") ? config["idle_hours"].to_i : @idle_hours
        min_messages = config&.key?("min_messages") ? config["min_messages"].to_i : DEFAULT_MIN_MESSAGES
        next unless aged?(session.updated_at, Time.now.utc - idle_hours * 3600)
        next if session.messages.size < min_messages

        due << { id: id, agent: session.vars["agent"].to_s, updated_at: session.updated_at }
      end
      due.sort_by { |s| s[:updated_at].to_s }
    end

    def harvest_declared?(profile)
      config = profile.respond_to?(:harvest) ? profile.harvest : nil
      return false unless config && Coercion.truthy?(config["enabled"])

      matcher_configured?(profile)
    end

    def aged?(updated_at, cutoff)
      return false if Coercion.blank?(updated_at)

      Time.iso8601(updated_at.to_s) <= cutoff
    rescue ArgumentError
      false
    end

    # One worker per window across N workers — the tick's claim idiom.
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
      @logger&.public_send(level, "[harvest] #{message}")
    rescue StandardError
      nil
    end
  end
end