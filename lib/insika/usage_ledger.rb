# frozen_string_literal: true

module Insika
  # Fixed-window counters on the KV Store (item 33 / §12 G7): the durable side of
  # the edge limits. One scope, keys shaped "kind:id:window_start" — the window
  # start bucketed on the epoch keeps every process/worker on the SAME bucket
  # without coordination (the Store's transaction serializes the read-modify-write,
  # in-process via the fiber semaphore and cross-process via BEGIN IMMEDIATE).
  #
  # Growth is bounded: each `add` garbage-collects the (kind, id) pair's PREVIOUS
  # window key, so an active entity holds at most 2 keys at any time and an idle
  # one converges to 1.
  class UsageLedger
    SCOPE = "usage_counters"

    def initialize(store:)
      @store = store
    end

    # Adds `by` to the current window's counter of (kind, id) -> the NEW total.
    def add(kind, id, window:, by: 1, now: Time.now)
      start = window_start(now, window)
      key = key_for(kind, id, start)
      @store.transaction do
        total = @store.get(SCOPE, key).to_i + by
        @store.set(SCOPE, key, total)
        @store.delete(SCOPE, key_for(kind, id, start - window))
        total
      end
    end

    # Current window's total for (kind, id). Missing/expired -> 0.
    def count(kind, id, window:, now: Time.now)
      @store.get(SCOPE, key_for(kind, id, window_start(now, window))).to_i
    end

    private

    def window_start(now, window)
      (now.to_i / window) * window
    end

    def key_for(kind, id, start)
      "#{kind}:#{id}:#{start}"
    end
  end
end
