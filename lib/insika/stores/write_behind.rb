# frozen_string_literal: true

require "delegate"

module Insika
  module Stores
    # Write-behind for diagnostic scopes. A write to one of `scopes` stays in
    # memory and a background task writes everything pending in ONE transaction
    # every `interval` seconds, so a turn never waits for the store's write lock
    # on behalf of a trace. Several writes of a key in one interval (a trace is
    # read-modify-write per tool call) become one write of its last value, which
    # also cuts what the database has to log.
    #
    # Reads in this process see the pending value. Other processes see it after
    # the next flush, and a crash loses at most one interval: acceptable for
    # traces and metrics, never for sessions, tasks or checkpoints — keep those
    # out of `scopes`. A scope matches by its base name ("traces:acme" ->
    # "traces"). Without a reactor (scripts, specs), or once `max_pending` keys
    # are waiting, writes go straight through: backpressure, not loss.
    class WriteBehind < SimpleDelegator
      def initialize(inner, scopes:, interval: 0.2, max_pending: 10_000, logger: nil)
        super(inner)
        @inner = inner
        @scopes = scopes.map(&:to_s).freeze
        @interval = interval
        @max_pending = max_pending
        @logger = logger
        @pending = {} # [scope, key] => serialized value (a read parses its own copy)
        @flusher = nil
        @types = Memory.new # the backends' shared type model, for the fail-fast check
      end

      def get(scope, key)
        k = [scope, key]
        @pending.key?(k) ? JSON.parse(@pending[k]) : @inner.get(scope, key)
      end

      def set(scope, key, value)
        return @inner.set(scope, key, value) unless defer?(scope, key)

        @pending[[scope, key]] = @types.send(:serialize, value) # fail-fast, same type model as the backends
        start_flusher
        value
      end

      def delete(scope, key)
        had = !@pending.delete([scope, key]).nil?
        @inner.delete(scope, key) || had
      end

      def list(scope, prefix = nil)
        pending = @pending.keys.filter_map { |s, k| k if s == scope && (prefix.nil? || k.start_with?(prefix)) }
        (@inner.list(scope, prefix) | pending).sort
      end

      # Writes everything pending now, in one transaction. A failure keeps the
      # values for the next flush (a value written meanwhile wins). -> count written
      def flush
        return 0 if @pending.empty?

        batch = @pending
        @pending = {}
        @inner.transaction { batch.each { |(scope, key), raw| @inner.set(scope, key, JSON.parse(raw)) } }
        batch.size
      rescue StandardError => e
        @pending = batch.merge(@pending)
        @logger&.warn("write-behind flush failed (#{batch.size} pending kept): #{e.message}")
        0
      end

      private

      # A key already pending always stays deferred, or a read here would return
      # its older pending value after a write went straight through.
      def defer?(scope, key)
        return false unless @scopes.include?(scope.to_s.sub(/:.*/, "")) && Fiber.scheduler

        @pending.key?([scope, key]) || @pending.size < @max_pending
      end

      # A transient task under the reactor itself, not under the request that
      # wrote first: it must outlive that request and never keep the reactor up.
      def start_flusher
        return if @flusher&.alive?

        @flusher = Async::Task.new(Fiber.scheduler, transient: true, annotation: "write-behind flush") do |task|
          loop do
            task.sleep(@interval)
            flush
          end
        ensure
          flush # a stopping worker writes what is left
        end
        @flusher.run
      end
    end
  end
end
