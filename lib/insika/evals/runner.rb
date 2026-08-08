# frozen_string_literal: true

require_relative "golden"
require_relative "assertions"

module Insika
  module Evals
    # Replays golden cases through a Transport and evaluates each. Pure over the
    # Transport (injected) — the fake makes the orchestration unit-testable offline;
    # the HttpTransport makes a real run.
    #
    # Multi-turn: a case's turns replay IN ORDER under one conversation id
    # (`eval-<id>`); earlier turns build context, the assertion runs on the LAST
    # turn's result. A turn that errors aborts the rest of that conversation (there's
    # nothing to continue from) and fails the case.
    class Runner
      # `tokens` is what the whole case cost, summed over its turns, or nil when no
      # turn reported usage. `cached` is how much of that was served from the prompt
      # cache, carried separately because it is the number that explains a total.
      # Only the refinement gate reads them (RFC-0013 §3.9 records a run's cost); the
      # report and the exit code are untouched.
      RunCase = Struct.new(:result, :timings, :tokens, :cached, keyword_init: true)

      # judge: an Evals::Judge (optional). When set, a case with a rubric whose turn
      # ran cleanly gets a subjective verdict attached on top of the deterministic pass.
      #
      # capabilities: what the DEPLOYMENT has, per agent — anything answering
      # `#for(agent_id)` with { "tools" =>, "capabilities" => } or nil. Used to skip a
      # case the deployment cannot satisfy (RFC-0014 §3.2), BEFORE spending a turn on
      # it. nil (or an unknown agent) = no resolution, and then a case with `requires`
      # RUNS and says so in the report: "could not rule it out" is not a reason to
      # stop testing something, and a suite that shrinks in silence is the failure
      # this feature exists to avoid.
      #
      # pairwise: an Evals::Pairwise (optional, RFC-0014 §3.4). Only cases carrying a
      # `reference:` are compared, and the verdict never touches pass/fail — it is the
      # answer to "can we replace it", reported beside the suite's own verdict.
      def initialize(transport:, judge: nil, conv_map: {}, capabilities: nil, pairwise: nil)
        @transport = transport
        @judge = judge
        @conv_map = conv_map || {}
        @capabilities = capabilities
        @pairwise = pairwise
      end

      # [Golden] -> [RunCase]. Each RunCase carries the CaseResult (for the report) +
      # per-turn timings (for `--mode perf`).
      def run(goldens)
        goldens.map { |g| run_case(g) }
      end

      def run_case(golden)
        skip = skip_reason(golden)
        return RunCase.new(result: Assertions.skip(golden, skip), timings: []) if skip

        # A backend that resolves state from a pre-existing conversation (e.g. consumer-app
        # needs a real Chat UUID as X-Chat-Id) supplies it via conv_map; otherwise the
        # synthetic "eval-<id>" keeps the adapter's own multi-turn continuation.
        conv = @conv_map[golden.id] || "eval-#{golden.id}"
        turns = []
        timings = []
        spent = []
        cached = []
        golden.user_turns.each do |message|
          outcome = @transport.turn(agent: golden.agent, conv: conv, message: message)
          timings << { ttfb: outcome.ttfb, total: outcome.total }
          spent << billed_tokens(outcome.usage)
          cached << cached_tokens(outcome.usage)
          turns << outcome.result
          break if outcome.result.error
        end
        last = turns.last
        # Tool/content assertions read the last turn (unchanged); the policy checks
        # read every turn — "one question per reply" is a rule about each of them.
        result = Assertions.evaluate(golden, last, turns: turns)
        # Subjective layer: only when a judge is configured, the case has a rubric, and
        # the turn ran cleanly (nothing to judge on an errored turn).
        result.judge = @judge.score(golden: golden, result: last) if @judge && result.rubric && result.error.nil?
        # Against the incumbent (RFC-0014 §3.4). Same rule as the judge: nothing to
        # compare on a turn that errored — half a conversation would lose the
        # comparison for a reason that has nothing to do with the agent.
        result.pairwise = @pairwise.compare(golden: golden, turns: turns) if @pairwise && result.error.nil?
        RunCase.new(result: result, timings: timings, tokens: sum_tokens(spent),
                    cached: sum_tokens(cached))
      end

      private

      # nil when NO turn reported usage; otherwise the sum of the ones that did. A
      # partially-metered case is reported as what was actually measured, low rather
      # than absent — a budget under-counting is a smaller lie than a budget that
      # throws the number away because one leg was silent.
      def sum_tokens(spent)
        counted = spent.compact
        counted.empty? ? nil : counted.sum
      end

      # What the turn actually SENT, cache included. The engine's `total_tokens` is
      # input + output and DELIBERATELY excludes the cached prefix (`Executor#usage_of`
      # reports `cached_tokens` alongside it), so reading it as the cost of a turn
      # under-reads a cached identity by an order of magnitude.
      #
      # Measured on the pilot: one real turn reports `total_tokens: 88` with
      # `cached_tokens: 26624`. A refinement budget built on the first number would
      # have let a run send ~300× what its ceiling said. Cached tokens are cheaper
      # than fresh ones; they are not free, and a ceiling has to see them.
      def billed_tokens(usage)
        return nil unless usage.is_a?(Hash)

        total = read(usage, "total_tokens")
        return nil if total.nil?

        total + cached_tokens(usage).to_i
      end

      def cached_tokens(usage)
        return nil unless usage.is_a?(Hash)

        values = [read(usage, "cached_tokens"), read(usage, "cache_creation_tokens")].compact
        values.empty? ? nil : values.sum
      end

      def read(usage, key)
        value = usage[key] || usage[key.to_sym]
        value&.to_i
      end

      # -> the reason to skip, or nil to run. A case with no `requires` always runs
      # (and never even asks), which keeps the whole existing corpus untouched.
      def skip_reason(golden)
        return nil unless golden.requirements?

        available = @capabilities&.for(golden.agent)
        return nil if available.nil? # unresolved: run it, and the report says so

        unmet = Assertions.unmet_requirements(golden, available)
        unmet.empty? ? nil : unmet.join("; ")
      end
    end
  end
end
