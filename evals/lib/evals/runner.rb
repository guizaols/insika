# frozen_string_literal: true

require_relative "golden"
require_relative "assertions"

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
    def initialize(transport:, judge: nil)
      @transport = transport
      @judge = judge
    end

    # [Golden] -> [RunCase]. Each RunCase carries the CaseResult (for the report) +
    # per-turn timings (for `--mode perf`).
    def run(goldens)
      goldens.map { |g| run_case(g) }
    end

    def run_case(golden)
      conv = "eval-#{golden.id}"
      last = nil
      timings = []
      golden.user_turns.each do |message|
        outcome = @transport.turn(agent: golden.agent, conv: conv, message: message)
        timings << { ttfb: outcome.ttfb, total: outcome.total }
        last = outcome.result
        break if last.error
      end
      result = Assertions.evaluate(golden, last)
      # Subjective layer: only when a judge is configured, the case has a rubric, and
      # the turn ran cleanly (nothing to judge on an errored turn).
      result.judge = @judge.score(golden: golden, result: last) if @judge && result.rubric && result.error.nil?
      RunCase.new(result: result, timings: timings)
    end
  end
end
