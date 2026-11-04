# frozen_string_literal: true

module Insika
  # Logs WHERE a worker's reactor is stuck. Falcon SIGKILLs a worker whose
  # health-check fiber has not run for 30s; this catches the stall long before
  # that. A fiber in the reactor stamps the clock every 0.5s; a plain Thread
  # watches the stamp and, while it is older than threshold_ms, logs the
  # reactor thread's backtrace (the fiber holding it) every second.
  # Opt-in diagnostic: INSIKA_STALL_LOG_MS.
  module StallWatchdog
    TICK = 0.5

    def self.start(threshold_ms:, logger: $stderr)
      reactor = Thread.current
      stamp = now
      Async(transient: true) do
        loop do
          stamp = now
          sleep TICK
        end
      end
      Thread.new do
        loop do
          sleep 1
          lag_ms = ((now - stamp) * 1000).round
          next if lag_ms < threshold_ms

          frames = (reactor.backtrace || []).first(25).join(" | ")
          logger.puts("[stall] pid=#{Process.pid} lag=#{lag_ms}ms at #{frames}")
        end
      end
    end

    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
