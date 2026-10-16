# frozen_string_literal: true

module Insika
  module Harvest
    # C7 — the eval half of the double gate (D7). Scores ONE candidate by
    # RUNNING it — the Refinement::Gate mechanism, with the skill's apply:
    #
    #   1. clone the agent into `<agent>-harvest-<run8>`,
    #   2. copy its instruction files, write the candidate skill into the
    #      clone's AGENT-scoped SkillStore and enable it on the clone's
    #      allowlist (the clone's catalog then serves it — the skill is gated
    #      by being *usable*, not by prose),
    #   3. replay the golden set against the clone over the ordinary public
    #      surface, compare to the accepted baseline,
    #   4. ANY regression disqualifies,
    #   5. destroy the clone in an `ensure`.
    #
    # Judges are MANDATORY in exactly the three refusal shapes the refined
    # gate already encodes (no baseline / all-red baseline / judged baseline
    # without a judge) — the P18 stamp. A skill that regresses ANY golden case
    # is rejected — this gate is a veto, never a score to argue with.
    class Gate
      # The verdict for one candidate. `passed` is the only field the caller
      # acts on; the rest is what an operator reads.
      Report = Data.define(:candidate_id, :passed, :reason, :cases, :passed_cases,
                           :baseline_cases, :regressions, :report, :tokens, :cached, :probe) do
        def to_h
          { "candidate_id" => candidate_id, "passed" => passed, "reason" => reason,
            "cases" => cases, "passed_cases" => passed_cases, "baseline_cases" => baseline_cases,
            "regressions" => regressions, "report" => report, "tokens" => tokens,
            "cached" => cached, "probe" => probe }
        end
      end

      DEFAULT_TOLERANCE = 0.05

      # skill_catalog: the graph's catalog (overlays the SkillStore) — the
      # apply writes into the store then RELOADS it, so the clone's next
      # dispatch serves the skill. judge_factory: the settings["evals"] panel
      # (the same one the refinement gate receives).
      def initialize(profiles:, agent_files:, goldens:, baselines:, skill_store:,
                     skill_catalog:, transport_factory:, capabilities_factory: nil,
                     judge_factory: nil, pairwise_factory: nil, session_store: nil,
                     tolerance: DEFAULT_TOLERANCE)
        @profiles = profiles
        @agent_files = agent_files
        @goldens = goldens
        @baselines = baselines
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @transport_factory = transport_factory
        @capabilities_factory = capabilities_factory
        @judge_factory = judge_factory
        @pairwise_factory = pairwise_factory
        @session_store = session_store # the probe sessions to delete after
        @tolerance = tolerance
      end

      # skill: the candidate's { name:, description:, body:, triggers: }.
      # -> Report. Never raises for an ordinary refusal (no cases, no
      # baseline, a replay that blew up).
      # probe_cases: the origin conversation's customer turns ([[String]]),
      # empty unless the agent turned the probe on. With no golden cases the
      # probe is the whole gate (nothing to veto); with golden cases it runs
      # after the golden replay passed.
      def score(agent_id:, skill:, run_id:, probe_cases: [])
        cases = @goldens.for_agent(agent_id)
        if cases.empty? && probe_cases.empty?
          return refusal(skill, "the agent has no golden cases — nothing to gate against")
        end

        baseline = judge = nil
        if cases.any?
          baseline = @baselines.get(agent_id)
          judge = @judge_factory&.call
          refused = golden_refusal(agent_id, skill, baseline, judge)
          return refused if refused
        end

        pairwise = nil
        if probe_cases.any?
          pairwise = @pairwise_factory&.call
          if pairwise.nil?
            return refusal(skill, "probe_no_judge: the probe is on but no pairwise judge is configured — " \
                                  "configure the judge panel (Studio → Settings → Evals) or turn " \
                                  "`harvest.probe.enabled` off for '#{agent_id}'")
          end
        end

        clone_id = clone_id_for(agent_id, run_id)
        # Fresh per gate call: candidates of one harvest run share run_id, and
        # the server continues an existing session by conv id.
        tag = SecureRandom.hex(4)
        begin
          profile = build_clone(agent_id, clone_id)
          before = converse_all(clone_id, probe_cases, tag, "before")
          again = converse_all(clone_id, probe_cases, tag, "again") # the noise floor
          install_skill(profile, clone_id, skill)
          # No golden cases: nothing to veto, the probe below decides alone.
          report = if cases.any?
                     verdict(skill, replay(cases, clone_id, judge), baseline, @tolerance)
                   else
                     Report.new(candidate_id: skill["name"], passed: true, reason: nil, cases: 0,
                                passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
                                tokens: nil, cached: nil, probe: nil)
                   end
          return report unless report.passed && probe_cases.any?

          after = converse_all(clone_id, probe_cases, tag, "after")
          # A case with an errored turn on either side expresses no preference:
          # "no answer" against an answer is a timeout, not a win.
          probe = Probe.verdict(before.zip(again, after).map { |b, g, a| case_verdict(pairwise, b, g, a) })
          report.with(passed: probe["passed"], reason: probe["reason"], probe: probe)
        rescue StandardError => e
          refusal(skill, "gate failed to run: #{e.class}: #{e.message}")
        ensure
          destroy_clone(clone_id)
          destroy_probe_sessions(tag) if probe_cases.any?
        end
      end

      def clone_id_for(agent_id, run_id) = "#{agent_id}-harvest-#{run_id.to_s.delete('-')[0, 8]}"

      def passing_cases(baseline)
        (baseline["cases"] || {}).count { |_id, entry| entry.is_a?(Hash) && entry["pass"] }
      end

      def judged?(baseline)
        (baseline["cases"] || {}).any? { |_id, entry| entry.is_a?(Hash) && !entry["score"].nil? }
      end

      private

      def baseline_size(baseline) = (baseline["cases"] || {}).size

      # The P18 refusals — only meaningful when there ARE golden cases.
      # -> Report | nil
      def golden_refusal(agent_id, skill, baseline, judge)
        if baseline.nil?
          return refusal(skill, "no recorded baseline for '#{agent_id}' — " \
                                "run `insika evals:baseline import` or record one before gating")
        end
        if passing_cases(baseline).zero?
          return refusal(skill, "the recorded baseline for '#{agent_id}' has no PASSING case " \
                                "(#{baseline_size(baseline)} recorded, all failing) — nothing could " \
                                "regress, so every candidate would pass. Fix the agent or the cases, " \
                                "then re-record the baseline from a green run")
        end
        return nil unless judge.nil? && judged?(baseline)

        refusal(skill, "the recorded baseline for '#{agent_id}' carries judge scores but no " \
                       "judge is configured — a rubric'd case with no verdict counts as a " \
                       "PASS, so every candidate would beat it. Configure the judge panel " \
                       "(Studio → Settings → Evals, or `settings[\"evals\"][\"judges\"]`) or " \
                       "re-record the baseline without one")
      end

      # Same profile, same tools, same guardrails — only the id and the skill
      # differ. Copying the profile rather than editing the real one is what
      # makes this safe to run against production: the live agent is never
      # touched, not even for a moment.
      def build_clone(agent_id, clone_id)
        profile = @profiles.fetch(agent_id) ||
                  (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")

        @profiles.put(profile.with(id: clone_id))
        current_files(agent_id).each { |name, body| @agent_files.write(clone_id, name, body) }
        profile
      end

      # D7: the skill lands into the clone's AGENT-scoped SkillStore (the
      # store position IS the identity), and the clone's profile `skills`
      # gains the name — so the clone's catalog serves it and the model can
      # load_skill it.
      def install_skill(profile, clone_id, skill)
        name = skill["name"].to_s
        @skill_store.write(name, skill["body"].to_s, agent: clone_id)
        enabled = profile.skills.nil? ? nil : (Array(profile.skills).map(&:to_s) | [name])
        @profiles.put(profile.with(id: clone_id, skills: enabled))
        @skill_catalog.reload
      end

      # A case's verdict: after vs before. A win only counts when the skill
      # ALSO beats a second, independent run without it (again): two runs of
      # the same agent differ, and the judge credits that variance to the skill
      # (a never-loaded skill "won" 2 of 3 cases in scripts/probe_control.rb).
      # Beating both is near-certain for a real gain and needs two lucky draws
      # for noise. nil when either side errored.
      def case_verdict(pairwise, before, again, after)
        return nil unless before && after

        verdict = pairwise.compare_texts(ours: after, theirs: before)
        return verdict unless verdict&.outcome == Insika::Evals::Pairwise::BETTER

        second = again && pairwise.compare_texts(ours: after, theirs: again)
        return verdict if second&.outcome == Insika::Evals::Pairwise::BETTER

        verdict.class.new(outcome: Insika::Evals::Pairwise::COMPARABLE, vs: verdict.vs, judges: verdict.judges,
                          order_dependent: verdict.order_dependent,
                          reason: "noise: won against one run without the skill but not the second " \
                                  "(#{second ? second.outcome : 'no second run'})")
      end

      # One conversation per probe case, on a fresh conv id per phase. A case
      # that hit an errored turn is nil (no comparison). Redacted before it
      # leaves for the judge, the same masking the miner uses.
      def converse_all(clone_id, probe_cases, tag, phase)
        return [] if probe_cases.empty?

        transport = @transport_factory.call
        probe_cases.each_with_index.map do |turns, i|
          conv = "probe-#{tag}-#{i}-#{phase}"
          ran = []
          turns.each do |message|
            ran << transport.turn(agent: clone_id, conv: conv, message: message).result
            break if ran.last.error
          end
          next nil if ran.last&.error

          Insika::Safety::Detectors.redact(Insika::Evals::Pairwise.transcript(turns, ran)).first
        end
      end

      # The probe sessions hold raw customer text under ids no customer var
      # points at (LGPD forget cannot find them), so they go with the clone.
      # ponytail: scans every session id; an index by prefix if gating gets hot.
      def destroy_probe_sessions(tag)
        return unless @session_store

        prefix = "probe-#{tag}-"
        @session_store.each_id.select { |id| id.to_s.split(":").last.to_s.start_with?(prefix) }
                      .each { |id| @session_store.delete(id) }
      rescue StandardError => e
        warn "[harvest] could not delete the probe sessions '#{prefix}*': #{e.class}: #{e.message}"
      end

      def current_files(agent_id)
        @agent_files.list(agent_id).each_with_object({}) do |name, acc|
          acc[name] = @agent_files.read(agent_id, name).to_s
        end
      end

      def replay(cases, clone_id, judge)
        retargeted = cases.map { |g| g.class.new(**g.to_h.merge(agent: clone_id)) }
        runner = Insika::Evals::Runner.new(transport: @transport_factory.call, judge: judge,
                                           capabilities: @capabilities_factory&.call)
        runner.run(retargeted)
      end

      def verdict(skill, ran, baseline, tolerance)
        results = ran.map(&:result)
        regressions = Insika::Evals::Baseline.compare(results, baseline, tolerance: tolerance)
        passed = results.count(&:pass?)
        graded = results.reject(&:skipped?).size
        spent = ran.filter_map(&:tokens)
        cached = ran.filter_map(&:cached)

        Report.new(
          candidate_id: skill["name"], passed: regressions.empty?,
          reason: regressions.empty? ? nil : regression_reason(regressions),
          cases: graded, passed_cases: passed,
          baseline_cases: (baseline["cases"] || {}).size,
          regressions: regressions.map { |r| { "id" => r.id, "kind" => r.kind, "detail" => r.detail } },
          report: Insika::Evals::Report.to_h(results, at: Time.now.utc.iso8601),
          tokens: spent.empty? ? nil : spent.sum,
          cached: cached.empty? ? nil : cached.sum, probe: nil
        )
      end

      def regression_reason(regressions)
        "#{regressions.size} regression(s): " +
          regressions.first(3).map { |r| "#{r.id} (#{r.kind})" }.join(", ")
      end

      def refusal(skill, reason)
        Report.new(candidate_id: skill["name"], passed: false, reason: reason,
                   cases: 0, passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
                   tokens: nil, cached: nil, probe: nil)
      end

      # Both halves tolerant of a missing one; runs in an `ensure` after a
      # failure that may have happened before either was created.
      def destroy_clone(clone_id)
        @agent_files.list(clone_id).each { |name| @agent_files.delete(clone_id, name) }
        begin
          Array(@skill_store.names(agent: clone_id)).each do |name|
            @skill_store.delete(name, agent: clone_id)
          end
        rescue StandardError
          nil # a leftover skill record is clutter, never servable without the profile
        end
        @profiles.delete(clone_id)
        # the catalog keeps the clone's skills in memory until reloaded — the
        # next gate's "before" pass must not be served this candidate
        @skill_catalog.reload
      rescue StandardError => e
        warn "[harvest] could not delete the gate clone '#{clone_id}': #{e.class}: #{e.message}"
      end
    end
  end
end