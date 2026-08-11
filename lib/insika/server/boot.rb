# frozen_string_literal: true

require "async"

module Insika
  module Server
    # Turns the components into a service.
    # MANDATORY order, no parallelism: plugins → stores → recovery → (app
    # for the listen). "Never accepts a request before recovery" is guaranteed BY
    # CONSTRUCTION: the listen (Falcon) only runs after `#call` returns the app, and
    # `#call` only returns after `Recovery.run` finishes.
    class Boot
      # wiring: object with the named steps (load_plugins/build_stores/
      # recovery/app) — the config/wiring.rb. logger: simple IO (default $stdout;
      # nil silences). app: overrides the wiring's `app` step — for a serving arm
      # (config.ru) that assembles its own Rack app around the wiring; the
      # "recovery before the listen" guarantee is unchanged (#call still only
      # returns after recovery).
      def initialize(wiring, logger: $stdout, app: nil)
        @wiring = wiring
        @logger = logger
        @app = app
      end

      # -> Rack app ready for the `run`. A store failure at boot (corrupted
      # file → StoreError) PROPAGATES and aborts the process (coming up
      # without durability is worse than not coming up); an unrecoverable task does NOT
      # bring down the boot (Recovery already marks it :failed).
      def call
        @wiring.load_plugins
        @wiring.build_stores
        warn_if_ephemeral
        summary = run_recovery
        log("boot: recovery complete — #{summary[:resumed].size} resumed, " \
            "#{summary[:failed].size} failed")
        @app || @wiring.app
      end

      private

      # Recovery dispatches resume_task, which creates task fibers — needs a
      # current reactor. At config.ru load (Falcon) there is NO reactor: the Sync { }
      # creates one and, by structured concurrency, only returns when the resume
      # fibers FINISH (recovery + turns completed before the listen — slower
      # boot, semantically safe). Under an already-current reactor (tests
      # inside Async), it runs directly: returns after the resume DISPATCH, with
      # the turns still in flight — also correct: "recovery before the listen" =
      # dispatch before the listen, not turn completion.
      def run_recovery
        return do_recovery if Async::Task.current?

        Sync { do_recovery }
      end

      # Task recovery THEN delegation recovery: the delegation
      # sweep re-delivers completed-but-undelivered async delegations, and depends
      # on the task sweep having re-dispatched any in-flight children first. Both
      # create task fibers, so both must run inside the reactor scope of run_recovery.
      #
      # The TASK sweep is additionally gated per boot generation:
      # its "orphaned :running" test cannot see a sibling worker's live fiber, so
      # only the worker that claims the generation sweeps — the others would steal
      # in-flight turns. The delegation and channel sweeps stay ungated: each of
      # their records carries its own transactional claim (at-most-once holds
      # however many workers sweep). Duck-typed: a wiring without the claim (test
      # doubles, single-process arms) sweeps unconditionally.
      def do_recovery
        summary =
          if skip_task_sweep?
            log("boot: task sweep skipped — another worker claimed this boot generation")
            { resumed: [], failed: [] }
          else
            @wiring.recovery.run
          end
        recover_delegations
        recover_channel_deliveries
        summary
      end

      def skip_task_sweep?
        @wiring.respond_to?(:claim_recovery_sweep) && !@wiring.claim_recovery_sweep
      end

      # Duck-typed (like durable?): a wiring without async delegation just omits it.
      def recover_delegations
        return unless @wiring.respond_to?(:recover_delegations)

        result = @wiring.recover_delegations
        log("boot: delegations re-delivered — #{Array(result && result[:delivered]).size}")
      end

      # replies a previous process committed but never handed to the
      # channel. Runs AFTER the task recovery for the same reason the delegation
      # sweep does — a resumed turn writes its own outbox record at its terminal, and
      # sweeping first would miss it.
      def recover_channel_deliveries
        return unless @wiring.respond_to?(:recover_channel_deliveries)

        result = @wiring.recover_channel_deliveries
        log("boot: channel replies re-dispatched — #{Array(result && result[:dispatched]).size}")
      end

      # Durability: without a durable backend, nothing is resumed after a
      # restart — warns loudly at boot so we don't come up "without a net" by mistake. The
      # test wiring (double) may not expose `durable?`; in that case, silence.
      def warn_if_ephemeral
        return unless @wiring.respond_to?(:durable?)
        return if @wiring.durable?

        log("boot: WARNING — EPHEMERAL backend (no INSIKA_DB): recovery will " \
            "not resume anything after a restart.")
      end

      def log(message)
        @logger&.puts(message)
      end
    end
  end
end
