# frozen_string_literal: true

require "time"
require "date"

module Insika
  module Harvest
    # C8 — the   second gate: the store's target METRIC RATE over
    # the criterion's window, compared to the frozen baseline's rate. Outcome
    # is EVIDENCE — the only verdict this object can produce is "the store is
    # measurably worse than the accepted state" and "there is nothing to
    # compare against".
    #
    # The ruler is a RATE (metric ÷ first stage), never a total: the frozen
    # baseline covers a ≥ 28-day span while the window is 72 h — comparing the
    # raw counts would flag a store that tripled its traffic as "worse" (fewer
    # absolute sales in 3 days than in 28). Both sides fold the same
    # denominator, so the comparison measures the per-unit health, which is
    # what the audit can actually read back.
    #
    # Refuse-with-a-named-reason, never pass, on missing data (the P18 lesson
    # applied to the second ruler): no frozen baseline, no criterion, no
    # funnel store, a fold that has not converged, a frozen span shorter than
    # the criterion's `min_span`, a baseline whose rate cannot be computed.
    class ConversionGate
      Result = Data.define(:passed, :reason, :metric, :window, :current,
                           :baseline, :threshold, :snapshot_ref) do
        # The candidate's conversion_gate record — the operator's review card
        # shows the ruler (both rates), never just a verdict.
        def to_h
          { "passed" => passed, "reason" => reason&.to_s, "metric" => metric,
            "window" => window, "current" => current, "baseline" => baseline,
            "threshold" => threshold, "snapshot_ref" => snapshot_ref }
        end
      end

      # funnel_store: the   FunnelStore (nil = the gate REFUSES — a
      # store without a ruler cannot promote on outcome, D6).
      # criterion: the boot-loaded Harvest::Criterion (nil = refuse).
      def initialize(funnel_store:, criterion:)
        @funnel_store = funnel_store
        @criterion = criterion
      end

      # -> Result. NEVER passes on missing data (D6).
      def call(tenant:, agent:)
        return refuse(:no_criterion) if @criterion.nil?
        return refuse(:no_funnel) if @funnel_store.nil?

        baseline = @funnel_store.baseline(tenant: tenant, agent: agent)
        return refuse(:no_frozen_baseline) if baseline.nil?

        # The criterion's metric is a stage NAME from the   declaration
        # (D5). The seed token "primary" resolves to the frozen snapshot's
        # primary stage — the declaration's own vocabulary, never a gem
        # constant .
        metric = resolve_metric(@criterion.rule.metric, baseline)
        return refuse(:metric_mismatch) if metric != baseline["primary"].to_s

        # min_span is LIVE (D5): the frozen baseline must cover the span the
        # criterion pre-registered — a number nobody re-froze to a shorter
        # span is not a number the gate may compare against.
        return refuse(:baseline_span_short) if span_short?(baseline, @criterion.rule.min_span)

        baseline_rate = rate_of(baseline["stages"] || {}, metric)
        # A baseline whose conversion was nil when frozen (no first-stage
        # events) cannot be the accepted state's ruler.
        return refuse(:no_baseline_rate) if baseline_rate.nil?

        window_hours = @criterion.rule.window.to_s.delete_suffix("h").to_i
        window_stages = fold_window(tenant: tenant, agent: agent, hours: window_hours)
        return refuse(:no_fold) if window_stages.empty?

        current_rate = rate_of(window_stages, metric)
        # The window folded no comparable denominator (no first-stage events
        # over the window) — there is nothing to compare.
        return refuse(:no_fold) if current_rate.nil?

        threshold = @criterion.rule.threshold.to_f
        snapshot_ref = "funnel:#{tenant_id(tenant)}:#{agent}:#{baseline['frozen_at']}"

        if current_rate >= baseline_rate * (1 - threshold)
          Result.new(passed: true, reason: nil, metric: metric,
                     window: @criterion.rule.window.to_s, current: current_rate,
                     baseline: baseline_rate, threshold: threshold,
                     snapshot_ref: snapshot_ref)
        else
          Result.new(passed: false, reason: :conversion_down,
                     metric: metric, window: @criterion.rule.window.to_s,
                     current: current_rate, baseline: baseline_rate,
                     threshold: threshold, snapshot_ref: snapshot_ref)
        end
      end

      private

      def refuse(reason)
        Result.new(passed: false, reason: reason,
                   metric: @criterion&.rule&.metric.to_s,
                   window: @criterion&.rule&.window.to_s,
                   current: nil, baseline: nil,
                   threshold: @criterion&.rule&.threshold,
                   snapshot_ref: nil)
      end

      # "primary" (the seed token) = the frozen snapshot's primary stage;
      # anything else is a literal stage name.
      def resolve_metric(token, baseline)
        token.to_s == "primary" ? baseline["primary"].to_s : token.to_s
      end

      # metric ÷ FIRST stage — the same denominator both sides fold, so the
      # totals' different spans cancel out. nil when the denominator is zero
      # (the ruler cannot be expressed).
      def rate_of(stages, metric)
        first = stages.keys.first
        denom = stages[first].to_f
        return nil if denom.zero?

        stages[metric].to_f / denom
      end

      # "28d" -> 28. The frozen span (from/to) must cover it — FreezeFunnelBaseline
      # enforces the same number at freeze time; this is the gate's own check
      # against a hand-written baseline or a moved criterion.
      def span_short?(baseline, min_span)
        return false if min_span.to_s.empty?

        from = baseline["from"].to_s
        to = baseline["to"].to_s
        return true if from.empty? || to.empty?

        days = (Date.iso8601(to) - Date.iso8601(from)).to_i
        days < min_span.to_s.delete_suffix("d").to_i
      rescue Date::Error
        true
      end

      # The criterion's window folded over the day cells (the
      # read) — the fold's day cells SUMMED by stage, so the gate can build
      # the window's rate the same way the baseline built its own.
      # -> { stage => count }
      def fold_window(tenant:, agent:, hours:)
        now = Time.now.utc
        from = (now - hours * 3600).strftime("%Y-%m-%d")
        to = now.strftime("%Y-%m-%d")
        @funnel_store.days(tenant: tenant, agent: agent, from: from, to: to)
                     .each_with_object(Hash.new(0)) do |(_day, counts), acc|
          counts.each { |stage, n| acc[stage] += n }
        end
      end

      def tenant_id(tenant)
        t = tenant.to_s
        t.empty? ? "platform" : t
      end
    end
  end
end