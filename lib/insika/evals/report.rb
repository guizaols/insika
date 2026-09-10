# frozen_string_literal: true

require "json"

module Insika
  module Evals
    # Renders a run's [CaseResult] as a machine-readable JSON blob (for the baseline
    # gating in) and a human-readable markdown summary.
    # Pure over the results — takes a clock value in, never reads it (so callers stay
    # deterministic/testable).
    module Report
      module_function

      # -> Hash ready for JSON. `at` is an ISO-8601 string stamped by the caller.
      #
      # `perf` is what each case COST, keyed by case id: `{"ms" =>, "turns" =>,
      # "tokens" =>, "cached" =>}`. Optional, because the answer to "did it pass" must
      # not depend on anyone having measured the clock — but a cross-harness table
      # without it is a table about correctness only, and a merchant asks how long the
      # customer waited before asking anything else. Wall clock is measured by the
      # RUNNER around the turn, never self-reported: it is the one column every
      # entrant can be held to.
      def to_h(results, at:, perf: nil)
        passed = results.count(&:pass?)
        skipped = results.count(&:skipped?)
        {
          "at" => at,
          "total" => results.size,
          "passed" => passed,
          # A skipped case is neither: counting it as failed is the lie this outcome
          # exists to stop, and counting it as passed is worse.
          "failed" => results.size - passed - skipped,
          "skipped" => skipped,
          "judge_pending" => results.count(&:judge_pending?),
          # Absent (not an empty tally) when nothing was compared — a run with no
          # pairwise is the normal one, and a zeroed block reads like every case tied.
          "pairwise" => pairwise_summary(results),
          "perf" => perf_summary(perf),
          "cases" => results.map do |r|
            {
              "id" => r.id, "agent" => r.agent, "pass" => r.pass?,
              "skipped" => r.skipped,
              "judge_pending" => r.judge_pending?, "error" => r.error,
              "checks" => r.checks.map do |c|
                { "name" => c.name, "pass" => c.pass, "detail" => c.detail,
                  "skipped" => (true if c.skipped?) }.compact
              end,
              "judge" => (r.judge && { "score" => r.judge.score, "pass" => r.judge.pass, "reason" => r.judge.reason }),
              "pairwise" => (r.pairwise && { "outcome" => r.pairwise.outcome, "vs" => r.pairwise.vs,
                                             "reason" => r.pairwise.reason, "judges" => r.pairwise.judges,
                                             "order_dependent" => r.pairwise.order_dependent }),
              "perf" => perf&.[](r.id)
            }.compact
          end
        }.compact
      end

      # -> counts by outcome, or nil when no case carried a reference. `human_assisted`
      # is counted separately and always printed: a "better" against a conversation a
      # PERSON typed is a different claim from one against the incumbent's model, and
      # the two must never be summed into one number somebody quotes.
      def pairwise_summary(results)
        compared = results.filter_map(&:pairwise)
        return nil if compared.empty?

        counts = compared.group_by(&:outcome).transform_values(&:size)
        { "compared" => compared.size,
          "human_assisted" => compared.count(&:human_assisted?),
          "order_dependent" => compared.count(&:order_dependent),
          "outcomes" => counts }
      end

      # nil when nothing was timed — an absent block, never a zeroed one: "nobody
      # measured" and "it took no time" are different facts, and a table that confuses
      # them publishes a harness as instant.
      def perf_summary(perf)
        measured = Array(perf&.values).select { |v| v["ms"] }
        return nil if measured.empty?

        case_ms = measured.map { |v| v["ms"].to_f }.sort
        turn_ms = measured.flat_map { |v| Array(v["turn_ms"]) }.compact.sort
        tokens = measured.filter_map { |v| v["tokens"] }
        { "cases_measured" => measured.size,
          "case_ms_p50" => percentile(case_ms, 50), "case_ms_p95" => percentile(case_ms, 95),
          "turn_ms_p50" => percentile(turn_ms, 50), "turn_ms_p95" => percentile(turn_ms, 95),
          # Absent rather than zero when no provider reported usage — most rival
          # harnesses will not, and a zero there reads as free.
          "tokens_total" => (tokens.sum unless tokens.empty?),
          "tokens_measured" => tokens.size }.compact
      end

      def percentile(sorted, p)
        return nil if sorted.empty?

        r = (p / 100.0) * (sorted.length - 1)
        lo = sorted[r.floor]
        hi = sorted[r.ceil]
        (lo + ((hi - lo) * (r - r.floor))).round
      end

      def to_json(results, at:, perf: nil)
        JSON.pretty_generate(to_h(results, at: at, perf: perf))
      end

      PAIRWISE_MARK = { "better" => "🟢", "comparable" => "🟡", "worse" => "🔴",
                        "split" => "⚖️", "unknown" => "❔" }.freeze

      # Never without `vs:` — see `pairwise_summary`.
      def pairwise_line(v)
        flip = v.order_dependent ? " (order-dependent)" : ""
        "#{PAIRWISE_MARK.fetch(v.outcome, '·')} vs incumbent (#{v.vs}): #{v.outcome}#{flip} — #{v.reason}"
      end

      def pairwise_block(summary)
        counts = summary["outcomes"].map { |k, n| "#{n} #{k}" }.join(" · ")
        lines = ["", "**vs incumbent** (#{summary['compared']} compared): #{counts}"]
        if summary["human_assisted"].positive?
          lines << "- #{summary['human_assisted']} against a HUMAN-ASSISTED transcript (a person typed " \
                   "part of the reference — not a model-vs-model result)"
        end
        if summary["order_dependent"].positive?
          lines << "- #{summary['order_dependent']} flipped when the transcripts were swapped, " \
                   "and were reported as comparable"
        end
        lines
      end

      # Human summary. One line per case; failing checks nested underneath.
      def to_markdown(results, at:, perf: nil)
        h = to_h(results, at: at, perf: perf)
        lines = ["# Eval report — #{at}", "",
                 "**#{h['passed']}/#{h['total'] - h['skipped']} passed** · #{h['failed']} failed" \
                 "#{" · #{h['skipped']} skipped" if h['skipped'].positive?}" \
                 "#{" · #{h['judge_pending']} awaiting judge" if h['judge_pending'].positive?}", ""]
        results.each do |r|
          if r.skipped?
            # WITH the reason, always: "12 skipped" alone is indistinguishable from a
            # suite that quietly stopped testing anything.
            lines << "- ⏭️ `#{r.id}` (#{r.agent}) — skipped: #{r.skipped}"
            next
          end

          took = perf&.dig(r.id, "ms")
          lines << "- #{r.pass? ? '✅' : '❌'} `#{r.id}` (#{r.agent})" \
                   "#{" · #{(took / 1000.0).round(1)}s" if took}" \
                   "#{'  ⏳ judge pending' if r.judge_pending?}"
          r.failures.each { |c| lines << "    - ❌ #{c.name}: #{c.detail}" }
          # A grader the transport could not feed. Printed even on a passing case:
          # "passed" over checks nobody could run is the claim this line prevents.
          r.skipped_checks.each { |c| lines << "    - ⏭️ #{c.name}: #{c.detail}" }
          if r.judge
            v = r.judge
            lines << "    - #{v.pass ? '✅' : '❌'} judge: #{v.score} — #{v.reason}"
          end
          lines << "    - #{pairwise_line(r.pairwise)}" if r.pairwise
        end
        if (summary = h["perf"])
          lines << "" << "**time** (#{summary['cases_measured']} case(s)): " \
                   "case p50/p95 #{summary['case_ms_p50']} / #{summary['case_ms_p95']} ms · " \
                   "turn p50/p95 #{summary['turn_ms_p50']} / #{summary['turn_ms_p95']} ms"
        end
        lines.concat(pairwise_block(h["pairwise"])) if h["pairwise"]
        "#{lines.join("\n")}\n"
      end
    end
  end
end
