# frozen_string_literal: true

module Insika
  # Hands freed memory back to the OS once a worker goes quiet. After a burst, glibc
  # keeps what the turns freed inside its malloc arenas and the process stays at its
  # peak until something calls malloc_trim — a full GC alone returns nothing. On a
  # quiet pass (no turn in flight, enough allocated since the last trim) this runs a
  # full GC and then malloc_trim(0).
  #
  # A no-op where malloc_trim does not exist (macOS, musl, a jemalloc LD_PRELOAD
  # returns 0) or where `fiddle` is not in the bundle: it is not a gem dependency,
  # the reference deployment adds it to its Gemfile.
  class MemoryTrim
    INTERVAL = 60 # seconds between checks
    MIN_ALLOCATED = 1_000_000 # objects allocated since the last trim; less is not worth a full GC

    def self.malloc_trim
      require "fiddle"
      fn = Fiddle::Function.new(Fiddle::Handle::DEFAULT["malloc_trim"], [Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT)
      -> { fn.call(0) }
    rescue LoadError, StandardError # no fiddle, or no malloc_trim symbol (Fiddle::DLError)
      nil
    end

    def initialize(executor:, trim: self.class.malloc_trim, allocated: -> { GC.stat(:total_allocated_objects) })
      @executor = executor
      @trim = trim
      @allocated = allocated
      @last = @allocated.call
    end

    def enabled? = !@trim.nil?

    # One check. -> true when it trimmed.
    def run_once
      return false unless @executor.in_flight.empty?
      return false if @allocated.call - @last < MIN_ALLOCATED

      GC.start
      @trim.call
      @last = @allocated.call
      true
    end

    def start(parent:, interval: INTERVAL)
      return false unless enabled?

      parent.async do |t|
        t.annotate("insika-memory-trim")
        loop do
          sleep(interval)
          run_once
        rescue StandardError => e
          warn "[memory_trim] #{e.class}: #{e.message}"
        end
      end
      true
    end
  end
end
