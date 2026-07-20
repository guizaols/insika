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

    def initialize(transport:)
      @transport = transport
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
      RunCase.new(result: Assertions.evaluate(golden, last), timings: timings)
    end
  end
end
