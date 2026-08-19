# frozen_string_literal: true

require "json"
require "time"

module Insika
  module Soak
    # The mechanical fold: a results file plus its
    # frozen envelope becomes ONE verdict and the numbers behind it. Pure — no
    # clock, no network, no store, no randomness. This is where "pass/fail is
    # mechanical" lives: two people folding the same bytes get the same verdict.
    module Report
      VERDICTS = %i[pass fail insufficient invalid].freeze

      # The verdict plus its evidence. `reasons` name every breach; for a
      # `fail` the report-only metrics point the leak hunt. `:invalid` carries
      # NO metrics at all — a tampered file must not produce rates.
      Result = Data.define(:verdict, :reasons, :metrics, :envelope_sha, :run_id) do
        def pass? = verdict == :pass

        def to_h
          {
            "verdict" => verdict.to_s, "reasons" => reasons,
            "metrics" => metrics.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v },
            "envelope_sha" => envelope_sha, "run_id" => run_id
          }
        end

        # Human report (Doctor::Report idiom).
        def to_s(color: false)
          head = "SOAK #{run_id} — #{verdict.to_s.upcase}"
          head += "  [#{envelope_sha}]" unless envelope_sha.nil?
          lines = [head]
          unless reasons.empty?
            lines << "  breaches:"
            reasons.each { |r| lines << "    - #{r}" }
          end
          lines.concat(metric_lines) if verdict != :invalid
          lines << leak_hunt if verdict == :fail && leak_hunt
          lines.join("\n")
        end

        private

        def f(key, default = "-") = metrics.key?(key) ? metrics[key] : default

        def metric_lines
          [
            "  turns=#{f(:turns)} snapshots=#{f(:snapshots)} restarts=#{f(:restarts)} " \
            "error_rate=#{f(:error_rate)} no_usage_rate=#{f(:no_usage_rate)}",
            "  rss: slope=#{f(:rss_slope_mb_per_day)} MB/day  growth_ratio=#{f(:rss_growth_ratio)}  " \
            "peak=#{f(:rss_peak_mb)} MB",
            "  prep p95: #{f(:prep_p95_ms)} ms (first #{f(:prep_p95_first_ms)} / last #{f(:prep_p95_last_ms)}, " \
            "drift #{f(:prep_p95_drift_ratio)})",
            "  total p95: #{f(:total_p95_ms)} ms   ttft p95: #{f(:ttft_p95_ms)} ms",
            "  coverage=#{f(:coverage_ratio)}  max_gap=#{f(:max_gap_s)}s  thin_hours=#{f(:thin_hours)}"
          ]
        end

        def leak_hunt
          return nil unless metrics[:rss_growth_ratio].to_f > 1.0

          heap_grew = (metrics[:heap_growth_ratio].to_f > 1.0)
          if heap_grew
            "leak hunt: the Ruby heap grew with RSS (heap_growth_ratio=#{metrics[:heap_growth_ratio]}) — " \
            "Ruby-side retention; start with retained objects and per-turn allocations."
          else
            "leak hunt: RSS climbed while the Ruby heap stayed flat — allocator/fragmentation " \
            "or a native buffer; start outside the Ruby heap."
          end
        end
      end

      module_function

      # `records` is any Enumerable of lines — parsed Hashes AND raw strings
      # (lines that failed to parse travel through unparsed so the fold can
      # count them). The file reader stays separate so the fold is testable on
      # literals.
      def fold(records, envelope:)
        raise ArgumentError, "records must be an Enumerable" unless records.respond_to?(:each)

        items = records.to_a
        return insufficient(envelope, nil, "no records", {}) if items.empty?

        parsed = items.select { |l| l.is_a?(Hash) }
        malformed = items.length - parsed.length
        header = parsed.find { |l| l["t"] == "header" }
        return invalid(envelope, nil, "missing header record", {}) if header.nil?

        run_id = header["run_id"]
        header_sha = header["envelope_sha"]
        return invalid(envelope, run_id, "header envelope_sha #{header_sha.inspect} does not match #{envelope.sha.inspect}", {}) if header_sha != envelope.sha

        started = parse_time(header["started_at"])
        duration = envelope[:duration_hours]

        if !envelope.dry_run? && !envelope.calibrated?
          return invalid(envelope, run_id, "the run is not calibrated (write the E1 values into the envelope first)", {})
        end

        if malformed.positive? && malformed.to_f / items.length > 0.005
          return invalid(envelope, run_id, "malformed lines: #{malformed} of #{items.length}", {})
        end

        snapshots = parsed.select { |l| l["t"] == "snapshot" }
        offender = snapshots.find { |s| s["envelope_sha"] != header_sha }
        unless offender.nil?
          return invalid(envelope, run_id,
                         "snapshot at hour #{offender['hour']} was stamped with a different envelope hash", {})
        end

        concurrent = concurrent_pids(snapshots)
        if !concurrent.nil? && envelope[:web_concurrency].to_i == 1
          return invalid(envelope, run_id,
                         "more than one pid inside boot_id #{concurrent.inspect} while web_concurrency == 1 " \
                         "(the RSS series is then not one process)", {})
        end

        turns = parsed.select { |l| l["t"] == "turn" }
        gaps = parsed.select { |l| l["t"] == "gap" }
        end_rec = parsed.find { |l| l["t"] == "end" }
        end_ok = end_rec && end_rec["reason"] == "complete"
        unless end_ok
          reason = end_rec ? end_rec["reason"] : "the runner never wrote an end record"
          return insufficient(envelope, run_id, "the run did not complete (end reason: #{reason})", {})
        end

        metrics = compute_metrics(turns, snapshots, gaps, header, started, duration, envelope)
        missing = missing_coverage(envelope, metrics)
        return insufficient(envelope, run_id, missing, metrics) if missing

        breaches = breaches(envelope, metrics)
        if breaches.empty?
          Result.new(verdict: :pass, reasons: [], metrics: metrics,
                     envelope_sha: envelope.sha, run_id: run_id)
        else
          Result.new(verdict: :fail, reasons: breaches, metrics: metrics,
                     envelope_sha: envelope.sha, run_id: run_id)
        end
      end

      # Ordinary least squares on [[hour, value]] -> { slope:, intercept:, se:,
      # upper_95: } where upper_95 = slope + 1.645 * se (one-sided). nil below
      # two points.
      def trend(points)
        return nil if points.nil? || points.length < 2

        n = points.length
        xs = points.map { |x, _| x.to_f }
        ys = points.map { |_, y| y.to_f }
        xbar = xs.sum / n
        ybar = ys.sum / n
        sxx = xs.sum { |x| (x - xbar)**2 }
        sxy = xs.zip(ys).sum { |x, y| (x - xbar) * (y - ybar) }
        slope = sxx.zero? ? 0.0 : sxy / sxx
        intercept = ybar - slope * xbar
        sse = xs.zip(ys).sum { |x, y| (y - (intercept + slope * x))**2 }
        se = sxx.zero? || n <= 2 ? 0.0 : Math.sqrt(sse / (n - 2) / sxx)
        { slope: slope, intercept: intercept, se: se, upper_95: slope + 1.645 * se }
      end

      # p-th percentile of a sorted array, linear interpolation — the SAME
      # formula as loadtest.rb#pct (including its 1-decimal rounding), so soak
      # and load-test numbers are comparable.
      def pct(sorted, p)
        return 0.0 if sorted.nil? || sorted.empty?

        r = (p / 100.0) * (sorted.length - 1)
        lo = sorted[r.floor]
        hi = sorted[r.ceil]
        (lo + (hi - lo) * (r - r.floor)).round(1)
      end

      # -- internals -----------------------------------------------------

      MB = 1_048_576.0
      private_constant :MB

      def parse_time(iso)
        Time.parse(iso.to_s)
      rescue ArgumentError
        nil
      end

      def invalid(envelope, run_id, reason, metrics)
        Result.new(verdict: :invalid, reasons: [reason], metrics: metrics,
                   envelope_sha: envelope&.sha, run_id: run_id)
      end

      def insufficient(envelope, run_id, reason, metrics)
        Result.new(verdict: :insufficient, reasons: [reason], metrics: metrics,
                   envelope_sha: envelope&.sha, run_id: run_id)
      end

      # A boot_id whose snapshots show two DIFFERENT pids at the SAME hour:
      # concurrent workers answering the sampler. A pid CHANGE across hours is a
      # respawn — evidence for the restarts gate, not for this one.
      def concurrent_pids(snapshots)
        by_hour = snapshots.each_with_object({}) do |s, acc|
          next unless s["vitals"].is_a?(Hash)

          key = [s["vitals"]["boot_id"], s["hour"]]
          (acc[key] ||= []) << s["vitals"]["pid"]
        end
        by_hour.each { |key, pids| return key[0] if pids.uniq.length > 1 }
        nil
      end

      def hour_of(turn, started)
        at = parse_time(turn["at"])
        return nil if at.nil? || started.nil?

        [((at - started) / 3600).floor, 0].max
      end

      def compute_metrics(turns, snapshots, gaps, header, started, duration, envelope)
        warmup = envelope[:warmup_hours]
        by_hour = Hash.new { |h, k| h[k] = [] }
        turns.each do |t|
          h = hour_of(t, started)
          by_hour[h] << t if h
        end

        usable = snapshots.select do |s|
          s["vitals"].is_a?(Hash) && !s.dig("vitals", "rss_bytes").nil? && s["error"].nil?
        end

        restarts, restart_events = count_restarts(snapshots)

        rss_fit = trend(usable.select { |s| s["hour"] > warmup }.map { |s| [s["hour"].to_f, s["vitals"]["rss_bytes"].to_f] })
        rss_ratio = rss_fit && rss_fit[:intercept].positive? ? growth_ratio(rss_fit, warmup, usable.map { |s| s["hour"] }.max) : nil

        heap_fit = trend(usable.filter_map { |s|
          live = s.dig("vitals", "gc", "heap_live_slots")
          live && [s["hour"].to_f, live.to_f]
        })
        heap_ratio = heap_fit && heap_fit[:intercept].positive? ? growth_ratio(heap_fit, warmup, usable.map { |s| s["hour"] }.max) : nil

        db_fit = trend(usable.filter_map { |s|
          bytes = s.dig("vitals", "db_bytes", "db")
          bytes && [s["hour"].to_f, bytes.to_f]
        })

        prep = turns.filter_map { |t| t.dig("timing", "prep_ms") }
        totals = turns.filter_map { |t| t["total_ms"] }
        ttfts = turns.filter_map { |t| t.dig("timing", "ttft_ms") }

        # Drift windows: (warmup+1..warmup+6) vs (duration-6..duration-1). A run
        # shorter than ~12h cannot hold two non-overlapping 6h windows: the last
        # window is then empty (drift is reported as "-", never gated) and the
        # first window runs to the end — it never reaches back into the warmup.
        first_lo, first_hi = warmup + 1, warmup + 6
        last_lo, last_hi = duration - 6, duration - 1
        if last_lo <= first_hi
          first_hi = last_hi
          last_lo = last_hi + 1
        end
        first_window = (first_lo..first_hi).flat_map { |h| by_hour[h] }.filter_map { |t| t.dig("timing", "prep_ms") }
        last_window = (last_lo..last_hi).flat_map { |h| by_hour[h] }.filter_map { |t| t.dig("timing", "prep_ms") }
        first_p95 = pct(first_window.sort, 95)
        last_p95 = pct(last_window.sort, 95)

        ok_turns = turns.count { |t| t["ok"] == true }
        no_usage = turns.count { |t| t["ok"] == true && !t["usage"].is_a?(Hash) }

        gap_s = [gaps.map { |g| g["seconds"].to_f }, inter_turn_gaps(turns)].flatten.max

        covered = usable.map { |s| s["hour"] }.uniq.length
        thin = (0...duration).count { |h| by_hour[h].length < envelope[:hourly_turn_floor] }

        {
          turns: turns.length,
          snapshots: snapshots.length,
          restarts: restarts,
          restart_events: restart_events,
          error_rate: turns.empty? ? 0.0 : (turns.length - ok_turns).to_f / turns.length,
          no_usage_rate: ok_turns.zero? ? 0.0 : no_usage.to_f / ok_turns,
          rss_slope_mb_per_day: rss_fit && (rss_fit[:upper_95] * 24 / MB).round(3),
          rss_growth_ratio: rss_ratio,
          rss_peak_mb: usable.empty? ? nil : (usable.map { |s| s["vitals"]["rss_bytes"] }.max / MB).round(1),
          heap_growth_ratio: heap_ratio,
          db_growth_mb_per_day: db_fit && (db_fit[:slope] * 24 / MB).round(3),
          tokens_per_turn: tokens_per_turn(turns),
          prep_p95_first_ms: first_window.empty? ? nil : first_p95,
          prep_p95_last_ms: last_window.empty? ? nil : last_p95,
          prep_p95_drift_ratio: last_window.empty? ? nil : drift_ratio(first_p95, last_p95),
          prep_p95_ms: prep.empty? ? nil : pct(prep.sort, 95),
          total_p95_ms: totals.empty? ? nil : pct(totals.sort, 95).round(1),
          ttft_p95_ms: ttfts.empty? ? nil : pct(ttfts.sort, 95).round(1),
          coverage_ratio: duration.zero? ? 0.0 : covered.to_f / duration,
          max_gap_s: gap_s.nil? ? nil : gap_s.round,
          thin_hours: thin
        }
      end

      def drift_ratio(first, last)
        return nil if first.nil? || last.nil?
        return 1.0 if first.zero? && last.zero?
        return Float::INFINITY if first.zero?

        (last / first).round(3)
      end

      def growth_ratio(fit, warmup, last_hour)
        return nil if last_hour.nil? || last_hour <= warmup

        (fit[:intercept] + fit[:upper_95] * last_hour) / (fit[:intercept] + fit[:upper_95] * warmup)
      end

      # restarts = distinct boot_id changes + worker respawns (pid changes
      # inside one boot_id), each minus the first. -> [count, [event strings]].
      def count_restarts(snapshots)
        boots = snapshots.each_with_object({}) do |s, acc|
          next unless s["vitals"].is_a?(Hash)

          (acc[s["vitals"]["boot_id"]] ||= []) << [s["hour"], s["vitals"]["pid"]]
        end
        events = []
        boots.each_value do |samples|
          prev = nil
          samples.sort_by(&:first).each do |hour, pid|
            events << "worker respawned at hour #{hour} (pid #{prev[1]} -> #{pid})" if prev && pid != prev[1]
            prev = [hour, pid]
          end
        end
        first_boot = snapshots.select { |s| s["vitals"].is_a?(Hash) }
                              .min_by { |s| s["hour"] }&.dig("vitals", "boot_id")
        boots.each_key do |boot|
          next if boot == first_boot

          events << "boot_id changed at hour #{boots[boot].map(&:first).min}"
        end
        [events.length, events]
      end

      def inter_turn_gaps(turns)
        sorted = turns.filter_map { |t| parse_time(t["at"]) }.sort
        sorted.each_cons(2).map { |a, b| b - a }
      end

      def tokens_per_turn(turns)
        totals = turns.filter_map { |t| t.dig("usage", "total_tokens") }
        return nil if totals.empty?

        (totals.sum.to_f / totals.length).round(1)
      end

      def missing_coverage(envelope, m)
        return "snapshot coverage: #{m[:coverage_ratio]} below #{envelope[:coverage_min_ratio]}" if m[:coverage_ratio] < envelope[:coverage_min_ratio]
        return "thin hours: #{m[:thin_hours]} hour(s) under #{envelope[:hourly_turn_floor]} turns" if m[:thin_hours].positive?
        if m[:max_gap_s] && m[:max_gap_s] > envelope[:gap_seconds_max]
          return "gap: #{m[:max_gap_s]}s exceeds #{envelope[:gap_seconds_max]}s"
        end
        return "no timing data (INSIKA_TURN_TIMING off on the target)" if m[:prep_p95_ms].nil?

        nil
      end

      def breaches(envelope, m)
        out = []
        m[:restart_events].each { |e| out << "restarts: #{e} (max #{envelope[:restarts_max]})" } if m[:restarts] > envelope[:restarts_max]
        out << "error_rate: #{m[:error_rate].round(4)} exceeds #{envelope[:error_rate_ceiling]}" if m[:error_rate] > envelope[:error_rate_ceiling]
        out << "no_usage_rate: #{m[:no_usage_rate].round(4)} exceeds #{envelope[:no_usage_rate_ceiling]} (a turn with no usage called no model)" if m[:no_usage_rate] > envelope[:no_usage_rate_ceiling]

        if m[:rss_growth_ratio] && m[:rss_growth_ratio] > envelope[:rss_growth_ratio]
          slope = m[:rss_slope_mb_per_day] || 0.0
          out << "rss_growth_ratio: #{m[:rss_growth_ratio].round(3)} exceeds #{envelope[:rss_growth_ratio]} " \
                 "(fitted slope #{slope} MB/day)"
        end

        if envelope[:rss_ceiling_mb] && m[:rss_peak_mb] && m[:rss_peak_mb] > envelope[:rss_ceiling_mb]
          out << "rss_peak: #{m[:rss_peak_mb]} MB exceeds ceiling #{envelope[:rss_ceiling_mb]} MB"
        end

        if m[:prep_p95_drift_ratio] && m[:prep_p95_drift_ratio] > envelope[:prep_p95_drift_ratio]
          out << "prep_p95_drift_ratio: #{m[:prep_p95_drift_ratio]} exceeds #{envelope[:prep_p95_drift_ratio]} " \
                 "(first #{m[:prep_p95_first_ms]} ms -> last #{m[:prep_p95_last_ms]} ms)"
        end

        if envelope[:prep_p95_ceiling_ms] && m[:prep_p95_ms] && m[:prep_p95_ms] > envelope[:prep_p95_ceiling_ms]
          out << "prep_p95: #{m[:prep_p95_ms]} ms exceeds ceiling #{envelope[:prep_p95_ceiling_ms]} ms"
        end

        if envelope[:total_p95_ceiling_ms] && m[:total_p95_ms] && m[:total_p95_ms] > envelope[:total_p95_ceiling_ms]
          out << "total_p95: #{m[:total_p95_ms]} ms exceeds ceiling #{envelope[:total_p95_ceiling_ms]} ms"
        end
        out
      end
    end
  end
end
