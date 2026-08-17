# frozen_string_literal: true

require "time"

module Insika
  # The periodic tick: durability stops waiting for a reboot. One
  # pass does two things, in this order:
  #
  #   1. DRAIN the outbox (`ChannelDelivery#sweep`) — replies a previous pass
  #      (or process) recorded and never claimed. Ungated: every record carries
  #      its own transactional claim, so N workers draining is safe.
  #   2. SWEEP stale orphaned tasks (`Recovery#run(stale_after:)`) — gated by a
  #      bucketed claim (`Recovery.claim_sweep` on "tick:<epoch/interval>"), so
  #      exactly one worker per window sweeps. The staleness threshold is the
  #      liveness gate: a live :running turn is bounded by turn_timeout, so
  #      anything untouched past it cannot be alive.
  #
  # It is NOT a job queue: no schedules, no priorities, no fan-out. The
  # refinement hook once pictured here is dropped by merit —
  # docs/REFINEMENT.md's "no scheduler in the engine" stands.
  class Tick
    # 60s: a customer waiting on WhatsApp is the deadline. 900s = 3x the
    # default turn_timeout (300s) — the rule, not the number: the threshold
    # must exceed the deployment's largest turn_timeout, or the sweep would
    # judge live turns orphaned.
    DEFAULT_INTERVAL = 60
    DEFAULT_STALE_AFTER = 900

    SCOPE = "tick"
    KEY = "claim"

    def initialize(store:, recovery:, channel_delivery:, logger: nil,
                   interval: DEFAULT_INTERVAL, stale_after: DEFAULT_STALE_AFTER,
                   sleeper: nil, retention: nil, funnel: nil, followup: nil)
      @store = store
      @recovery = recovery
      @channel_delivery = channel_delivery
      @logger = logger
      @interval = interval.to_i
      @stale_after = stale_after.to_i
      @sleeper = sleeper || method(:default_sleep)
      @retention = retention # WS8: the daily age-based sweep; nil = none
      @funnel = funnel # RFC-0032 C4: the tick-driven outcome fold; nil = none
      @followup = followup # RFC-0033 C5: the tick-driven follow-up firer; nil = none
    end

    # RFC-0032 C8: the fold is wired after the Tick is built (the graph passes
    # it to `executor.tick.funnel =` — the outcome/funnel stores come from the
    # spine). Setter + kwarg: same shape as `retention`.
    attr_accessor :funnel

    # RFC-0033 C9: the follow-up firer, wired after the Tick is built (same
    # shape as `funnel` — the stores come from the spine).
    attr_accessor :followup

    def enabled? = @interval.positive?

    # One pass, pure (no reactor needed): the serving loop calls it on a timer,
    # specs call it directly. A StoreError propagates to the loop, which logs
    # and keeps ticking.
    def run_once
      drained = @channel_delivery ? @channel_delivery.sweep : { dispatched: [] }
      summary = { dispatched: drained[:dispatched], resumed: [], failed: [] }
      # WS8 retention: cheap when not claimed (its own daily window) — the
      # O(n) scans never ride the 60 s loop.
      retention_summary = @retention&.run
      summary[:retention] = retention_summary if retention_summary
      # RFC-0032 C4: the outcome fold — one pass per claim window (D3), cheap
      # when another worker holds it. Sits next to retention, on the same tick.
      funnel_summary = @funnel&.run
      summary[:funnel] = funnel_summary if funnel_summary
      # RFC-0033 C5: the follow-up firer — the tick's third duty, gated by its
      # OWN claim window so the O(n) scans never ride the 60 s loop.
      followup_summary = @followup&.run
      summary[:followup] = followup_summary if followup_summary
      return summary unless claim_window

      result = @recovery.run(stale_after: @stale_after)
      summary.merge(resumed: result[:resumed], failed: result[:failed])
    end

    # The loop, spawned as a child of the turn supervisor (the
    # tick lives on the supervisor fiber — every serving arm gets it the moment
    # `supervised = true` matters, with no arm edits). A failing pass logs and
    # the loop continues: a sweeper that dies silently is the outage it exists
    # to prevent. Restartable: when the supervisor is recreated its children
    # died with it, so a stopped task is not a running one.
    def start(parent:)
      return false unless enabled?
      return true if @task&.running?

      @task = parent.async do |t|
        t.annotate("insika-tick")
        loop do
          @sleeper.call(@interval)
          run_once
        rescue StandardError => e
          log(:warn, "tick failed: #{e.class}: #{e.message}")
        end
      end
      true
    end

    private

    # One sweeper per window across N workers. Unlike the boot
    # claim (one key per generation), the tick reuses a SINGLE key with a
    # timestamp — a key per minute would be a slow leak in the store. The
    # read-check-write rides Store#transaction like every claim:
    # two workers racing the window serialize on the backend's lock and exactly
    # one sweeps.
    def claim_window
      now = Time.now.utc
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil # a corrupted claim is not a claim — take the window
        end
        if last.nil? || (now - last) >= @interval
          @store.set(SCOPE, KEY, { "claimed_at" => now.iso8601 })
          true
        else
          false
        end
      end
    end

    # Async when there is a reactor (production: the interval must not block
    # the worker), plain sleep otherwise (specs driving the loop by hand use an
    # injected sleeper anyway).
    def default_sleep(seconds)
      task = defined?(Async::Task) ? Async::Task.current? : nil
      task ? task.sleep(seconds) : sleep(seconds)
    end

    # Same contract as Recovery's: logging is pure observability and must never
    # alter the flow.
    def log(level, message)
      @logger&.public_send(level, "[tick] #{message}")
    rescue StandardError
      nil
    end
  end
end
