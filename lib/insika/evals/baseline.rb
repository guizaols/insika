# frozen_string_literal: true

require "json"

module Insika
  module Evals
    # Fase C gating (RFC-0008 §3.4). A baseline is the accepted state of the golden
    # set — `{ cases: { id => { pass, score } } }`. A gated run compares against it and
    # blocks only on a REGRESSION, so known-failing cases don't wedge the gate while a
    # real drop (a passing case that now fails, or a judge score that fell past the
    # tolerance) does. That's the pre-merge gate for prompt/tool/model changes.
    module Baseline
      Regression = Struct.new(:id, :kind, :detail, keyword_init: true)

      module_function

      # [CaseResult] -> baseline hash. `at` is stamped by the caller (kept out of here
      # so the module stays deterministic/testable).
      def snapshot(results, at:)
        {
          "at" => at,
          "cases" => results.each_with_object({}) do |r, h|
            h[r.id] = { "pass" => r.pass?, "score" => (r.judge&.score) }
          end
        }
      end

      def load(path) = JSON.parse(File.read(path))

      def write(path, results, at:)
        File.write(path, JSON.pretty_generate(snapshot(results, at: at)))
      end

      # Compares a run against a loaded baseline. -> [Regression]. Only cases present
      # in BOTH are compared: a new case (no baseline entry) never blocks the gate (it
      # shows in the report as ❌ but is not a "regression"); document this in README.
      #   • pass→fail : baseline pass, now failing (hard regression).
      #   • score-drop: baseline score - current judge score > tolerance (quality drift,
      #                 even if the case still technically passes).
      def compare(results, baseline, tolerance:)
        base = baseline["cases"] || {}
        results.filter_map do |r|
          b = base[r.id]
          next unless b

          if b["pass"] && !r.pass?
            Regression.new(id: r.id, kind: "pass→fail", detail: "was passing, now failing")
          elsif b["score"] && r.judge && (b["score"] - r.judge.score) > tolerance
            Regression.new(id: r.id, kind: "score-drop",
                           detail: "judge #{b['score']} -> #{r.judge.score} (> #{tolerance})")
          end
        end
      end
    end
  end
end
