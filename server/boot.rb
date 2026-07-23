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
      # nil silences).
      def initialize(wiring, logger: $stdout)
        @wiring = wiring
        @logger = logger
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
        @wiring.app
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

      # Task recovery THEN delegation recovery (RFC-0010 Fase 2): the delegation
      # sweep re-delivers completed-but-undelivered async delegations, and depends
      # on the task sweep having re-dispatched any in-flight children first. Both
      # create task fibers, so both must run inside the reactor scope of run_recovery.
      def do_recovery
        summary = @wiring.recovery.run
        recover_delegations
        summary
      end

      # Duck-typed (like durable?): a wiring without async delegation just omits it.
      def recover_delegations
        return unless @wiring.respond_to?(:recover_delegations)

        result = @wiring.recover_delegations
        log("boot: delegations re-delivered — #{Array(result && result[:delivered]).size}")
      end

      # Durability: without a durable backend, nothing is resumed after a
      # restart — warns loudly at boot so we don't come up "without a net" by mistake. The
      # test wiring (double) may not expose `durable?`; in that case, silence.
      def warn_if_ephemeral
        return unless @wiring.respond_to?(:durable?)
        return if @wiring.durable?

        log("boot: WARNING — EPHEMERAL backend (no HARNESS_DB): recovery will " \
            "not resume anything after a restart (doc 02 §6).")
      end

      def log(message)
        @logger&.puts(message)
      end
    end
  end
end
