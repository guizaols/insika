# frozen_string_literal: true

module Insika
  # shutdown is a drain, not a kill (docs/DEPLOY.md, process model
  # The serving arms install this around the Executor. On the first
  # SIGTERM/SIGINT the process stops accepting new turns (`Executor#begin_drain!`
  # — a turn arriving mid-drain is left `:queued` for the next boot's recovery)
  # and waits up to `timeout` seconds for the in-flight ones; only then does the
  # ordinary stop proceed. A second signal skips the wait — the operator insisting
  # means now. Whatever the deadline abandons dies `:running` with the process and
  # the next boot generation's task sweep replays it from its checkpoint
  # (side-effect skip on resume is what makes that replay safe).
  #
  # Mechanics, because trap context is narrow: the handler writes ONE byte into a
  # self-pipe and returns. A plain watcher THREAD — not a fiber: at install time
  # the serving reactor may not exist yet, and the drain must not depend on it —
  # blocks on that pipe, runs the drain, and then delivers the stop the trap
  # withheld by raising Interrupt in the serving thread. That is exactly the
  # exception async-container's own trap would have raised, so everything
  # downstream (Falcon worker teardown, reactor close, Litestream's final sync)
  # is unchanged; this class only buys the turns time before it.
  class Shutdown
    DEFAULT_TIMEOUT = 20 # seconds — the number DEPLOY.md records and entrypoint.sh builds on
    POLL = 0.05

    # The one-call form the serving arms use: resolves the deadline, sets the
    # traps, parks the watcher. The CALLING thread is captured as the stop target
    # — install from the thread that runs the server.
    #
    # `executors:` drains N graphs on one signal. Signals are a
    # PROCESS concern, and `Signal.trap` keeps only the last handler — so a second
    # `install` per graph would silently leave the earlier graphs dying mid-turn.
    # The host installs ONCE, naming every graph it embedded. `executor:` is the
    # single-graph sugar every serving arm still uses.
    def self.install(executor: nil, executors: nil, timeout: nil, logger: $stdout, signals: %w[INT TERM])
      new(executors: executors || executor, timeout: timeout || default_timeout,
          logger: logger).install!(signals)
    end

    # INSIKA_DRAIN_TIMEOUT (validated by EnvSchema); absent/garbage -> the default.
    def self.default_timeout
      Integer(EnvSchema.read("INSIKA_DRAIN_TIMEOUT").to_s)
    rescue ArgumentError
      DEFAULT_TIMEOUT
    end

    # `interrupt` is the injectable stop delivery (specs); the default raises
    # Interrupt in `target`, the thread that installed the traps.
    def initialize(executor: nil, executors: nil, timeout:, logger: $stdout,
                   target: Thread.current, interrupt: nil)
      @executors = Array(executors || executor)
      @timeout = timeout
      @logger = logger
      @target = target
      @interrupt = interrupt || -> { @target.raise(Interrupt) }
      @reader, @writer = IO.pipe
      @signaled = false
    end

    attr_reader :timeout

    def install!(signals = %w[INT TERM])
      signals.each { |sig| Signal.trap(sig) { signal_received } }
      @thread = Thread.new { watch }
      @thread.name = "insika-shutdown"
      self
    end

    # Runs in TRAP context: a flag flip and a pipe write, nothing else — except
    # when the drain is already underway, where a repeated signal means "stop
    # waiting" and the Interrupt is delivered immediately.
    def signal_received
      return @interrupt.call if @signaled

      @signaled = true
      begin
        @writer.write_nonblock("!")
      rescue IOError, SystemCallError
        nil # pipe gone (process already unwinding): nothing left to schedule
      end
    end

    # The watcher's whole life: parked on the pipe until the first signal, then
    # drain and hand the stop back to the normal path.
    def watch
      @reader.read(1)
      drain
      @interrupt.call
    end

    # Closes the intake and waits for the in-flight turns, bounded by the
    # deadline. With N executors the intake of EVERY one closes first, before any
    # waiting: draining them in sequence would let graph B keep taking turns while
    # graph A spends the deadline. -> { drained: bool, abandoned: [task ids] }
    def drain
      @executors.each(&:begin_drain!)
      log("shutdown: draining — #{in_flight.size} turn(s) in flight, deadline #{@timeout}s")
      deadline = monotonic + @timeout
      sleep(POLL) until in_flight.empty? || monotonic >= deadline

      abandoned = in_flight
      if abandoned.empty?
        log("shutdown: drained clean")
      else
        log("shutdown: deadline reached — abandoning #{abandoned.size} turn(s); " \
            "recovery replays them at the next boot")
      end
      { drained: abandoned.empty?, abandoned: abandoned }
    end

    private

    # The turns still running across every graph this shutdown owns.
    def in_flight = @executors.flat_map(&:in_flight)

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Observability only: a logger failure must never alter the drain.
    def log(message)
      @logger&.puts(message)
    rescue StandardError
      nil
    end
  end
end
