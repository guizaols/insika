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
      def to_h(results, at:)
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
          "cases" => results.map do |r|
            {
              "id" => r.id, "agent" => r.agent, "pass" => r.pass?,
              "skipped" => r.skipped,
              "judge_pending" => r.judge_pending?, "error" => r.error,
              "checks" => r.checks.map { |c| { "name" => c.name, "pass" => c.pass, "detail" => c.detail } },
              "judge" => (r.judge && { "score" => r.judge.score, "pass" => r.judge.pass, "reason" => r.judge.reason }),
              "pairwise" => (r.pairwise && { "outcome" => r.pairwise.outcome, "vs" => r.pairwise.vs,
                                             "reason" => r.pairwise.reason, "judges" => r.pairwise.judges,
                                             "order_dependent" => r.pairwise.order_dependent })
            }
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

      def to_json(results, at:)
        JSON.pretty_generate(to_h(results, at: at))
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
      def to_markdown(results, at:)
        h = to_h(results, at: at)
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

          lines << "- #{r.pass? ? '✅' : '❌'} `#{r.id}` (#{r.agent})#{'  ⏳ judge pending' if r.judge_pending?}"
          r.failures.each { |c| lines << "    - ❌ #{c.name}: #{c.detail}" }
          if r.judge
            v = r.judge
            lines << "    - #{v.pass ? '✅' : '❌'} judge: #{v.score} — #{v.reason}"
          end
          lines << "    - #{pairwise_line(r.pairwise)}" if r.pairwise
        end
        lines.concat(pairwise_block(h["pairwise"])) if h["pairwise"]
        "#{lines.join("\n")}\n"
      end
    end
  end
end
