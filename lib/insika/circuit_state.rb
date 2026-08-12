# frozen_string_literal: true

require "time"

module Insika
  # The circuit breaker's durable state (WS3): one cell per
  # (tenant, provider/model ref) holding the recent failures and when the
  # circuit opened. The read-modify-write rides `@store.transaction` — the same
  # discipline as the dispatch claim (A1): two concurrent failures of the same
  # cell serialize, so the "10 failures in 60s" count is never lost to a race.
  #
  # States, standard semantics:
  #   :closed    fewer than `after` failures in the `within` window — attempts flow.
  #   :open      the window count is met AND the cooldown hasn't elapsed — the
  #              edge FAIL-FASTS (no provider call) with retry_after = remaining
  #              cooldown. Reached at the `after`-th failure, which stamps
  #              opened_at.
  #   :half_open the cooldown elapsed — the next attempt is the TRIAL: a success
  #              closes (record_success clears the cell), a failure reopens
  #              (a new failure count / opened_at).
  class CircuitState
    SCOPE = "circuit_state"

    # Timestamps are pruned to COUNT_LIMIT — a pathological loop cannot grow the
    # cell unboundedly (the window is 60s-wide; 100 reads and writes bounded).
    COUNT_LIMIT = 100

    Record = Data.define(:failures, :opened_at)

    def initialize(store:)
      @store = store
    end

    # Records ONE failure for (tenant, ref). If this failure makes the window
    # reach `after` and the circuit is not already open, it stamps opened_at
    # (the instant the breaker trips). -> :closed (still closed) | :open (just
    # tripped).
    def record_failure(tenant:, ref:, after: 10, within: 60, now: Time.now)
      key = key_for(tenant, ref)
      @store.transaction do
        record = load(key)
        cutoff = (now.to_i - within)
        retained = record.failures.select { |t| t > cutoff }.last(COUNT_LIMIT)
        failures = (retained + [now.to_i]).last(COUNT_LIMIT)
        opened_at = record.opened_at
        if opened_at.nil? && failures.size >= after
          opened_at = now.to_i
        end
        @store.set(SCOPE, key, { "failures" => failures, "opened_at" => opened_at })
        opened_at.nil? ? :closed : :open
      end
    end

    # A successful attempt CLOSES the circuit: the cell is cleared so the
    # failure window starts fresh (half-open trial success included).
    def record_success(tenant:, ref:)
      @store.delete(SCOPE, key_for(tenant, ref))
    end

    # -> :closed | :open | :half_open
    def state(tenant:, ref:, after: 10, within: 60, cooldown: 300, now: Time.now)
      record = load(key_for(tenant, ref))
      return :closed if record.failures.size < after

      opened = record.opened_at.to_i
      return :open if opened.zero? || (now.to_i - opened) < cooldown

      :half_open
    end

    # Seconds until the circuit can be retried (the remaining cooldown). nil
    # while closed.
    def retry_after(tenant:, ref:, cooldown: 300, now: Time.now)
      record = load(key_for(tenant, ref))
      return nil if record.failures.empty?

      opened = record.opened_at.to_i
      return nil if opened.zero?

      remaining = cooldown - (now.to_i - opened)
      remaining.positive? ? remaining : nil
    end

    private

    def key_for(tenant, ref) = "#{tenant || 'platform'}:#{ref}"

    def load(key)
      record = @store.get(SCOPE, key)
      return Record.new([], nil) if record.nil?

      Record.new(Array(record["failures"]), record["opened_at"])
    end
  end
end