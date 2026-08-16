# frozen_string_literal: true

module Insika
  # Opt-in per-turn latency breakdown (locate the
  # TTFB cost with real-turn data). OFF unless INSIKA_TURN_TIMING is set — when
  # off the Executor never allocates one and the hot path pays only `nil&.mark`.
  #
  # Splits a turn into the three windows that answer "is TTFB local or provider?":
  #   prep_ms  — prep_start -> ask: ALL local work before the provider call
  #              (context build, policy, guardrail detectors, chat assembly).
  #   ttft_ms  — ask -> first_token: the provider round-trip to the 1st token.
  #   gen_ms   — first_token -> done: streaming the rest of the response.
  #
  # Marks are monotonic; `mark` is first-write-wins so `first_token` records the
  # FIRST content chunk even though it is called on every chunk.
  #
  # `ttft_ms` is the PROVIDER's first token, not the first byte the customer can
  # read: TurnOutput publishes a message once it ends, so the customer-visible
  # answer lands inside `gen_ms`. Measuring the provider is the point —'s
  # baselines (~720 ms, provider-bound) stay comparable across that change.
  class TurnTiming
    # EnvSchema owns "is this flag on?" (1/true/yes/on) — the same predicate that
    # validates the :boolean keys, so a spelling `insika env` accepts is a spelling
    # the reader honours.
    def self.enabled?(env = ENV)
      Insika::EnvSchema.truthy?(Insika::EnvSchema.read("INSIKA_TURN_TIMING", env))
    end

    # The marks that only mean something under INSIKA_TURN_TIMING. A `breakdown:
    # false` clock (a channel turn with the flag off) ignores them and measures
    # only first_balloon_ms.
    BREAKDOWN_MARKS = %i[prep_start ask first_token done].freeze
    private_constant :BREAKDOWN_MARKS

    # breakdown: true (the default) is the flag-on clock: prep/ttft/gen/total.
    # false is the RFC-0027 C5 channel clock: only :inbound -> :first_balloon,
    # so a channel turn with the flag off still answers H-latência.
    def initialize(breakdown: true)
      @marks = {}
      @breakdown = breakdown
    end

    def mark(name)
      return unless @breakdown || !BREAKDOWN_MARKS.include?(name)

      @marks[name] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # -> Hash of phase deltas in ms (only the windows whose endpoints both fired;
    # a workflow turn has no ask/first_token, so those are simply absent).
    # RFC-0027 C5: first_balloon_ms is the inbound -> first outbox flush window.
    # A missing number is never a zero — no mark, no key.
    def to_h
      {
        prep_ms: delta(:prep_start, :ask),
        ttft_ms: delta(:ask, :first_token),
        gen_ms: delta(:first_token, :done),
        total_ms: delta(:prep_start, :done),
        first_balloon_ms: delta(:inbound, :first_balloon)
      }.compact
    end

    private

    def delta(from, to)
      return nil unless @marks[from] && @marks[to]

      ((@marks[to] - @marks[from]) * 1000).round(2)
    end
  end
end
