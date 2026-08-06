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
      RunCase = Struct.new(:result, :timings, keyword_init: true)

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
      def initialize(transport:, judge: nil, conv_map: {}, capabilities: nil)
        @transport = transport
        @judge = judge
        @conv_map = conv_map || {}
        @capabilities = capabilities
      end

      # [Golden] -> [RunCase]. Each RunCase carries the CaseResult (for the report) +
      # per-turn timings (for `--mode perf`).
      def run(goldens)
        goldens.map { |g| run_case(g) }
      end

      def run_case(golden)
        skip = skip_reason(golden)
        return RunCase.new(result: Assertions.skip(golden, skip), timings: []) if skip

        # A backend that resolves state from a pre-existing conversation (e.g. achei-b2b
        # needs a real Chat UUID as X-Chat-Id) supplies it via conv_map; otherwise the
        # synthetic "eval-<id>" keeps the adapter's own multi-turn continuation.
        conv = @conv_map[golden.id] || "eval-#{golden.id}"
        turns = []
        timings = []
        golden.user_turns.each do |message|
          outcome = @transport.turn(agent: golden.agent, conv: conv, message: message)
          timings << { ttfb: outcome.ttfb, total: outcome.total }
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
        RunCase.new(result: result, timings: timings)
      end

      private

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
