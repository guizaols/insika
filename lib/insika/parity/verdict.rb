# frozen_string_literal: true

require "time"

module Insika
  module Parity
    # Both halves of an exchange formatted IDENTICALLY, so the judge cannot tell
    # them apart by shape (anonymity by construction).
    def self.transcript(inbound, reply)
      "customer: #{inbound.to_s.strip}\nassistant: #{reply.to_s.strip}"
    end

    # C6 — the mechanical fold. Given the window's pairs and the frozen criterion,
    # produce ONE verdict and show its arithmetic. Pure: no store, no clock beyond
    # the injected `now`, no LLM. Every number the Studio prints comes from here,
    # so two people reading the same pairs get the same answer (E3).
    #
    # The order of the steps IS the rule:
    #   window -> pre-registration -> buckets -> volume -> sanity -> primary -> guards
    module Verdict
      module_function

      Report = Data.define(
        :verdict,        # :pass | :fail | :insufficient | :invalid
        :window,         # { from:, to:, days: }
        :counts,         # judged/decided/better/comparable/worse/split/unknown/
                         # silent/incomplete/human_assisted/open
        :daily,          # [{ date:, pairs:, decided: }]
        :per_agent,      # { agent => { decided:, win_or_tie:, worse:, meets: } }
        :win_or_tie, :win_or_tie_lower, :worse_rate,
        :undecided_rate, :incomplete_rate,
        :checks,         # [{ id:, met:, actual:, required:, note: }]
        :criterion_sha, :reason
      )

      DECIDED = %w[better comparable worse].freeze

      Check = Data.define(:id, :met, :actual, :required, :note)

      def fold(pairs:, criterion:, now: Time.now.utc)
        rule = criterion.rule
        from = now - (rule.window_days * 86_400)
        windowed = Array(pairs).select { |p| in_window?(p, from, now) }

        checks = []

        # 2. Pre-registration: a window whose pairs disagree about which file was
        # frozen is :invalid — a post-hoc edit produces NO verdict, not a worse one.
        sha = sha_check(windowed, criterion.sha)
        if sha && !sha.met
          checks << sha
          return build(verdict: :invalid, criterion: criterion, from: from, to: now,
                       rule: rule, counts: nil, daily: [], per_agent: {},
                       checks: checks, reason: sha.note)
        end
        checks << sha if sha

        # 3. Buckets: decided is better+comparable+worse against the incumbent's
        # model (`vs: agent`). human-assisted/silent/incomplete/open/split/unknown
        # are counted and reported, never in the denominator.
        counts = count(windowed)
        daily = daily_of(windowed, from, now, rule)
        per_agent = per_agent_of(windowed)

        # 4. Volume: every day at the floor, and enough decided pairs in total —
        # short volume is :insufficient (an honest "keep running"), never a fail.
        volume = volume_check(daily, rule)
        checks << volume
        decided_check = Check.new(id: :min_decided, met: counts[:decided] >= rule.min_decided,
                                  actual: counts[:decided], required: rule.min_decided,
                                  note: "decided #{counts[:decided]} < #{rule.min_decided}")
        checks << decided_check
        unless volume.met && decided_check.met
          notes = [volume.met ? nil : volume.note, decided_check.met ? nil : decided_check.note].compact
          return build(verdict: :insufficient, criterion: criterion, from: from, to: now,
                       rule: rule, counts: counts, daily: daily, per_agent: per_agent,
                       checks: checks, reason: notes.join("; "))
        end

        # 5. Sanity: a panel that cannot decide, or a mirror that cannot pair,
        # is not measuring anything -> :invalid. The denominator is the panel's
        # own work: judged pairs against a model — human-assisted pairs are
        # counted and reported, never in a denominator.
        judged = counts[:judged] - counts[:human_assisted]
        undecided_rate = judged.positive? ? (counts[:split] + counts[:unknown]).fdiv(judged) : 0.0
        undecided = Check.new(id: :undecided, met: undecided_rate <= rule.undecided_rate_ceiling,
                              actual: undecided_rate.round(4), required: "<= #{rule.undecided_rate_ceiling}",
                              note: "undecided rate #{undecided_rate.round(3)} > #{rule.undecided_rate_ceiling} " \
                                    "(#{counts[:split]} split, #{counts[:unknown]} unknown of #{judged} judged)")
        checks << undecided

        non_open = windowed.length - counts[:open]
        incomplete_rate = non_open.positive? ? counts[:incomplete].fdiv(non_open) : 0.0
        incomplete = Check.new(id: :incomplete, met: incomplete_rate <= rule.incomplete_rate_ceiling,
                               actual: incomplete_rate.round(4), required: "<= #{rule.incomplete_rate_ceiling}",
                               note: "incomplete rate #{incomplete_rate.round(3)} > #{rule.incomplete_rate_ceiling} " \
                                     "(#{counts[:incomplete]} of #{non_open} non-open pairs never got both halves)")
        checks << incomplete
        unless undecided.met && incomplete.met
          notes = [undecided.met ? nil : undecided.note, incomplete.met ? nil : incomplete.note].compact
          return build(verdict: :invalid, criterion: criterion, from: from, to: now,
                       rule: rule, counts: counts, daily: daily, per_agent: per_agent,
                       rates: { undecided: undecided_rate, incomplete: incomplete_rate },
                       checks: checks, reason: notes.join("; "))
        end

        # 6. Primary: the lower bound of the 95% Wilson interval on win-or-tie.
        # The estimator is NAMED in the criterion, so a point estimate can never be
        # quietly substituted.
        win_or_tie = counts[:decided].positive? ? (counts[:better] + counts[:comparable]).fdiv(counts[:decided]) : 0.0
        lower = wilson_lower(counts[:better] + counts[:comparable], counts[:decided])
        primary = Check.new(id: :primary, met: lower >= rule.win_or_tie_floor,
                            actual: { win_or_tie: win_or_tie.round(4), wilson_lower_95: lower.round(4) },
                            required: "#{rule.estimator} >= #{rule.win_or_tie_floor}",
                            note: "win-or-tie #{win_or_tie.round(3)} (wilson lower #{lower.round(3)}) " \
                                  "< floor #{rule.win_or_tie_floor}")
        checks << primary

        # 7. Guards: the worse tail on its own, and any store blocking its own cut.
        worse_rate = counts[:decided].positive? ? counts[:worse].fdiv(counts[:decided]) : 0.0
        worse = Check.new(id: :worse_rate, met: worse_rate <= rule.worse_rate_ceiling,
                          actual: worse_rate.round(4), required: "<= #{rule.worse_rate_ceiling}",
                          note: "worse rate #{worse_rate.round(3)} > #{rule.worse_rate_ceiling} " \
                                "(#{counts[:worse]} worse of #{counts[:decided]} decided)")
        checks << worse
        agent = per_agent_check(per_agent, rule)
        checks << agent if agent

        failed = [primary, worse, agent].compact.reject(&:met)
        unless failed.empty?
          return build(verdict: :fail, criterion: criterion, from: from, to: now,
                       rule: rule, counts: counts, daily: daily, per_agent: per_agent,
                       rates: { win_or_tie: win_or_tie, lower: lower, worse: worse_rate,
                                undecided: undecided_rate, incomplete: incomplete_rate },
                       checks: checks, reason: failed.map(&:note).join("; "))
        end

        build(verdict: :pass, criterion: criterion, from: from, to: now,
              rule: rule, counts: counts, daily: daily, per_agent: per_agent,
              rates: { win_or_tie: win_or_tie, lower: lower, worse: worse_rate,
                       undecided: undecided_rate, incomplete: incomplete_rate },
              checks: checks, reason: "the cut cleared: every check in the window is green")
      end

      # Wilson score interval, lower bound. Pure arithmetic, unit-tested against
      # published values (n=210, k=183 -> ~0.819).
      def wilson_lower(successes, n, z: 1.96)
        return 0.0 if n.to_i <= 0

        p_hat = successes.to_f / n
        z2 = z * z
        denominator = 1 + (z2 / n)
        centre = p_hat + (z2 / (2 * n))
        spread = Math.sqrt((p_hat * (1 - p_hat) + (z2 / (4 * n))) / n)
        (centre - (z * spread)) / denominator
      end

      # -- private helpers ---------------------------------------------------

      def in_window?(pair, from, to)
        created = pair.respond_to?(:created_at) ? pair.created_at : nil
        time = begin
          Time.iso8601(created.to_s)
        rescue ArgumentError
          nil
        end
        time && time >= from && time < to
      end
      private_class_method :in_window?

      # Pre-registration has nothing to stand on when NO pair carries the sha:
      # the window predates the freeze, and stamping a verdict on it is the same
      # post-hoc edit the mixed-sha rule exists to refuse.
      def sha_check(pairs, expected)
        shas = pairs.filter_map { |p| p.respond_to?(:criterion_sha) ? p.criterion_sha : nil }.compact.uniq
        if shas.length == 1 && shas.first == expected
          Check.new(id: :criterion_sha, met: true, actual: expected, required: expected, note: nil)
        elsif pairs.empty?
          # nothing to pre-register — the volume check owns the empty window
          Check.new(id: :criterion_sha, met: true, actual: expected, required: expected, note: nil)
        elsif shas.empty?
          Check.new(id: :criterion_sha, met: false, actual: "no pair stamped", required: expected,
                    note: "no pair in the window carries a criterion_sha — the window predates the freeze")
        else
          Check.new(id: :criterion_sha, met: false, actual: shas.join(" | "), required: expected,
                    note: "window carries #{shas.join(', ')}, expected the frozen #{expected}")
        end
      end
      private_class_method :sha_check

      def count(windowed)
        buckets = windowed.group_by { |p| bucket_of(p) }
        base = { judged: windowed.count { |p| p.status == :judged },
                 open: windowed.count { |p| p.status == :open } }
        { silent: buckets[:silent].to_a.length,
          incomplete: buckets[:incomplete].to_a.length,
          human_assisted: buckets[:human_assisted].to_a.length,
          better: buckets[:better].to_a.length, comparable: buckets[:comparable].to_a.length,
          worse: buckets[:worse].to_a.length, split: buckets[:split].to_a.length,
          unknown: buckets[:unknown].to_a.length }.merge(base).tap do |c|
          c[:decided] = c[:better] + c[:comparable] + c[:worse]
        end
      end
      private_class_method :count

      # A malformed verdict blob counts as :unknown, never as a preference — the
      # same rule Pairwise applies to a broken judge.
      def bucket_of(pair)
        return pair.status.to_sym unless pair.status == :judged

        verdict = pair.respond_to?(:verdict) && pair.verdict.is_a?(Hash) ? pair.verdict : nil
        return :unknown unless verdict

        return :human_assisted if verdict["vs"] == "human-assisted"

        outcome = verdict["outcome"].to_s
        DECIDED.include?(outcome) ? outcome.to_sym : outcome == "split" ? :split : :unknown
      end
      private_class_method :bucket_of

      # One entry per CALENDAR date the window touches, bucketed by each pair's
      # own date — the newest pairs must land on the grid, never outside the list.
      # `floor` is the daily requirement: pairs_per_day for a day whose full 24h
      # lie inside the window, 0 for the two boundary days — they are partial by
      # construction (`from` carries now's time of day), and holding a partial day
      # to a full floor would make the gate unreachable under constant traffic at
      # exactly the floor. Partial days are reported, never required.
      def daily_of(windowed, from, to, rule)
        by_day = windowed.group_by { |p| Time.iso8601(p.created_at.to_s).utc.strftime("%Y-%m-%d") }
        calendar_dates(from, to).map do |date|
          pairs = by_day[date].to_a
          decided = pairs.count { |p| DECIDED.include?(bucket_of(p).to_s) }
          { date: date, pairs: pairs.length, decided: decided,
            floor: full_day?(date, from, to) ? rule.pairs_per_day : 0 }
        end
      end
      private_class_method :daily_of

      def calendar_dates(from, to)
        dates = []
        day = Time.utc(from.utc.year, from.utc.month, from.utc.day)
        last = Time.utc(to.utc.year, to.utc.month, to.utc.day)
        while day <= last
          dates << day.strftime("%Y-%m-%d")
          day += 86_400
        end
        dates
      end
      private_class_method :calendar_dates

      def full_day?(date, from, to)
        y, m, d = date.split("-").map(&:to_i)
        day_start = Time.utc(y, m, d)
        day_end = day_start + 86_400
        [[to, day_end].min - [from, day_start].max, 0].max >= 86_400
      end
      private_class_method :full_day?

      def volume_check(daily, rule)
        short = daily.find { |d| d[:floor].positive? && d[:pairs] < d[:floor] }
        full_days = daily.count { |d| d[:floor].positive? }
        return Check.new(id: :volume, met: true,
                         actual: "#{full_days} full day(s) at >= #{rule.pairs_per_day}",
                         required: "#{rule.pairs_per_day} pairs on every full day",
                         note: nil) unless short

        Check.new(id: :volume, met: false,
                  actual: "#{short[:date]}: #{short[:pairs]} pairs",
                  required: "#{short[:floor]} pairs that day",
                  note: "day #{short[:date]} has #{short[:pairs]} pairs (floor #{short[:floor]})")
      end
      private_class_method :volume_check

      def per_agent_of(windowed)
        windowed.select { |p| DECIDED.include?(bucket_of(p).to_s) }
                .group_by { |p| p.agent.to_s }
                .transform_values do |pairs|
          decided = pairs.length
          win_or_tie = decided.positive? ? pairs.count { |p| %w[better comparable].include?(bucket_of(p).to_s) }.fdiv(decided) : 0.0
          { decided: decided, win_or_tie: win_or_tie.round(4),
            worse: pairs.count { |p| bucket_of(p) == :worse }, meets: nil }
        end
      end
      private_class_method :per_agent_of

      # A store with enough decided pairs blocks its own cut when its win-or-tie
      # sits under its own floor — even if the aggregate passes.
      def per_agent_check(per_agent, rule)
        blockers = per_agent.each_with_object({}) do |(agent, stats), acc|
          next if stats[:decided] < rule.per_agent_min_decided

          stats[:meets] = stats[:win_or_tie] >= rule.per_agent_win_or_tie_floor
          acc[agent] = stats[:win_or_tie] unless stats[:meets]
        end
        return nil if blockers.empty?

        Check.new(id: :per_agent, met: false, actual: blockers.map { |a, r| "#{a}: #{r}" }.join(", "),
                  required: ">= #{rule.per_agent_win_or_tie_floor} for stores with >= #{rule.per_agent_min_decided} decided",
                  note: blockers.map { |a, r| "#{a} sits at #{r.round(3)} (< #{rule.per_agent_win_or_tie_floor})" }.join("; "))
      end
      private_class_method :per_agent_check

      def build(verdict:, criterion:, from:, to:, rule:, counts:, daily:, per_agent:, checks:, reason:, rates: nil)
        r = rates || {}
        Report.new(
          verdict: verdict,
          window: { from: from.utc.iso8601, to: to.utc.iso8601, days: rule.window_days },
          counts: counts, daily: daily, per_agent: per_agent,
          win_or_tie: r[:win_or_tie]&.round(4), win_or_tie_lower: r[:lower]&.round(4),
          worse_rate: r[:worse]&.round(4),
          undecided_rate: r[:undecided]&.round(4), incomplete_rate: r[:incomplete]&.round(4),
          checks: checks, criterion_sha: criterion.sha, reason: reason
        )
      end
      private_class_method :build
    end
  end
end
