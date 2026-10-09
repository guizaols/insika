# frozen_string_literal: true

module Insika
  # Per-turn latency clock. Every turn runs one (a few clock reads); the turn's
  # numbers land in ModelMetricsStore's turn rows (#metrics). INSIKA_TURN_TIMING
  # only decides what the RESPONSE exposes (#to_h) and whether store calls count.
  #
  # Splits a turn into the three windows that answer "is TTFB local or provider?":
  #   prep_ms  — prep_start -> ask: ALL local work before the provider call
  #              (context build, policy, guardrail detectors, chat assembly).
  #   ttft_ms  — ask -> first_token: the provider round-trip to the 1st token.
  #   gen_ms   — first_token -> done: streaming the rest of the response.
  #   store_calls — store calls this turn made (+ store_calls_by: "op scope" => n).
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

    # Fiber-storage slot holding the running turn's clock. Child fibers (parallel
    # tool calls, context providers) inherit it, so their store calls count too.
    FIBER_KEY = :insika_turn_timing

    def self.current = Fiber[FIBER_KEY]

    # "config:<scope>" keeps its config scope; any other scope keeps its first
    # segment, so ids embedded in scope names do not split the breakdown.
    def self.scope_group(scope)
      parts = scope.to_s.split(":")
      parts.first == "config" ? parts.first(2).join(":") : parts.first.to_s
    end

    # breakdown: true (the default) exposes prep/ttft/gen/total in #to_h.
    # false exposes only first_balloon_ms (the flag-off contract); every mark is
    # still taken, so #metrics is complete either way.
    def initialize(breakdown: true)
      @marks = {}
      @breakdown = breakdown
      @tools = []
    end

    def mark(name)
      @marks[name] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # One tool call of this turn (ToolEnvelope#trace): [name, ok, ms].
    def tool(name, ok, ms) = @tools << [name.to_s, ok, ms]

    # Has this mark fired? Used by `SendMessage` to prove the channel clock was
    # stamped at 202 acceptance (`:inbound` before the debounce window), and by
    # the pipeline to know a threaded clock already started.
    def marked?(name) = @marks.key?(name)

    # -> Hash of phase deltas in ms (only the windows whose endpoints both fired;
    # a workflow turn has no ask/first_token, so those are simply absent).
    # first_balloon_ms is the inbound -> first outbox flush window.
    # A missing number is never a zero — no mark, no key.
    def to_h
      h = {
        prep_ms: delta(:prep_start, :ask),
        ttft_ms: delta(:ask, :first_token),
        gen_ms: delta(:first_token, :done),
        total_ms: delta(:prep_start, :done),
        first_balloon_ms: delta(:inbound, :first_balloon)
      }.compact
      h = h.slice(:first_balloon_ms) unless @breakdown
      return h unless @store_calls

      h.merge(store_calls: @store_calls.values.sum,
              store_calls_by: @store_calls.sort_by { |call, n| [-n, call] }.to_h)
    end

    # The turn row ModelMetricsStore keeps: every window, whatever the flag.
    # queue_ms is inbound -> pipeline start (debounce + FIFO wait), the part of
    # first_balloon_ms that is not the turn's own work. tools_ms sums the calls,
    # so parallel calls count more than their wall time.
    def metrics
      {
        "prep_ms" => delta(:prep_start, :ask), "ttft_ms" => delta(:ask, :first_token),
        "gen_ms" => delta(:first_token, :done), "total_ms" => delta(:prep_start, :done),
        "first_balloon_ms" => delta(:inbound, :first_balloon), "queue_ms" => delta(:inbound, :prep_start),
        "tools_ms" => (@tools.sum { |_, _, ms| ms.to_i } unless @tools.empty?),
        "tools" => (@tools unless @tools.empty?)
      }.compact
    end

    # One store call made during this turn (see Stores::TurnCounter).
    def count_store(op, scope)
      return unless @breakdown

      @store_calls ||= Hash.new(0)
      @store_calls["#{op} #{self.class.scope_group(scope)}"] += 1
    end

    private

    def delta(from, to)
      return nil unless @marks[from] && @marks[to]

      ((@marks[to] - @marks[from]) * 1000).round(2)
    end
  end
end
