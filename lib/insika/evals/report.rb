# frozen_string_literal: true

require "json"

module Insika
  module Evals
    # Renders a run's [CaseResult] as a machine-readable JSON blob (for the baseline
    # + gating in Fase C) and a human-readable markdown summary.
    # Pure over the results — takes a clock value in, never reads it (so callers stay
    # deterministic/testable).
    module Report
      module_function

      # -> Hash ready for JSON. `at` is an ISO-8601 string stamped by the caller.
      def to_h(results, at:)
        passed = results.count(&:pass?)
        {
          "at" => at,
          "total" => results.size,
          "passed" => passed,
          "failed" => results.size - passed,
          "judge_pending" => results.count(&:judge_pending?),
          "cases" => results.map do |r|
            {
              "id" => r.id, "agent" => r.agent, "pass" => r.pass?,
              "judge_pending" => r.judge_pending?, "error" => r.error,
              "checks" => r.checks.map { |c| { "name" => c.name, "pass" => c.pass, "detail" => c.detail } },
              "judge" => (r.judge && { "score" => r.judge.score, "pass" => r.judge.pass, "reason" => r.judge.reason })
            }
          end
        }
      end

      def to_json(results, at:)
        JSON.pretty_generate(to_h(results, at: at))
      end

      # Human summary. One line per case; failing checks nested underneath.
      def to_markdown(results, at:)
        h = to_h(results, at: at)
        lines = ["# Eval report — #{at}", "",
                 "**#{h['passed']}/#{h['total']} passed** · #{h['failed']} failed" \
                 "#{" · #{h['judge_pending']} awaiting judge (Fase B)" if h['judge_pending'].positive?}", ""]
        results.each do |r|
          lines << "- #{r.pass? ? '✅' : '❌'} `#{r.id}` (#{r.agent})#{'  ⏳ judge pending' if r.judge_pending?}"
          r.failures.each { |c| lines << "    - ❌ #{c.name}: #{c.detail}" }
          if r.judge
            v = r.judge
            lines << "    - #{v.pass ? '✅' : '❌'} judge: #{v.score} — #{v.reason}"
          end
        end
        "#{lines.join("\n")}\n"
      end
    end
  end
end
