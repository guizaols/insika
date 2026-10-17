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
                           :baseline_cases, :regressions, :report, :tokens, :cached) do
        def to_h
          { "candidate_id" => candidate_id, "passed" => passed, "reason" => reason,
            "cases" => cases, "passed_cases" => passed_cases, "baseline_cases" => baseline_cases,
            "regressions" => regressions, "report" => report, "tokens" => tokens,
            "cached" => cached }
        end
      end

      DEFAULT_TOLERANCE = 0.05

      # skill_catalog: the graph's catalog (overlays the SkillStore) — the
      # apply writes into the store then RELOADS it, so the clone's next
      # dispatch serves the skill. judge_factory: the settings["evals"] panel
      # (the same one the refinement gate receives).
      def initialize(profiles:, agent_files:, goldens:, baselines:, skill_store:,
                     skill_catalog:, transport_factory:, capabilities_factory: nil,
                     judge_factory: nil, tolerance: DEFAULT_TOLERANCE)
        @profiles = profiles
        @agent_files = agent_files
        @goldens = goldens
        @baselines = baselines
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @transport_factory = transport_factory
        @capabilities_factory = capabilities_factory
        @judge_factory = judge_factory
        @tolerance = tolerance
      end

      # skill: the candidate's { name:, description:, body:, triggers: }.
      # -> Report. Never raises for an ordinary refusal (no cases, no
      # baseline, a replay that blew up).
      def score(agent_id:, skill:, run_id:)
        cases = @goldens.for_agent(agent_id)
        return refusal(skill, "the agent has no golden cases — nothing to gate against") if cases.empty?

        baseline = @baselines.get(agent_id)
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

        judge = @judge_factory&.call
        if judge.nil? && judged?(baseline)
          return refusal(skill, "the recorded baseline for '#{agent_id}' carries judge scores but no " \
                                "judge is configured — a rubric'd case with no verdict counts as a " \
                                "PASS, so every candidate would beat it. Configure the judge panel " \
                                "(Studio → Settings → Evals, or `settings[\"evals\"][\"judges\"]`) or " \
                                "re-record the baseline without one")
        end

        clone_id = clone_id_for(agent_id, run_id)
        begin
          build_clone(agent_id, clone_id, skill)
          ran = replay(cases, clone_id, judge)
          verdict(skill, ran, baseline, @tolerance)
        rescue StandardError => e
          refusal(skill, "gate failed to run: #{e.class}: #{e.message}")
        ensure
          destroy_clone(clone_id)
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

      # Same profile, same tools, same guardrails — only the id and the skill
      # differ. Copying the profile rather than editing the real one is what
      # makes this safe to run against production: the live agent is never
      # touched, not even for a moment.
      def build_clone(agent_id, clone_id, skill)
        profile = @profiles.fetch(agent_id) ||
                  (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")

        @profiles.put(profile.with(id: clone_id))
        current_files(agent_id).each { |name, body| @agent_files.write(clone_id, name, body) }

        # D7: the skill lands into the clone's AGENT-scoped SkillStore (the
        # store position IS the identity), and the clone's profile `skills`
        # gains the name — so the clone's catalog serves it and the model can
        # load_skill it.
        name = skill["name"].to_s
        @skill_store.write(name, skill["body"].to_s, agent: clone_id)
        enabled = profile.skills.nil? ? nil : (Array(profile.skills).map(&:to_s) | [name])
        @profiles.put(profile.with(id: clone_id, skills: enabled))
        @skill_catalog.reload
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
          cached: cached.empty? ? nil : cached.sum
        )
      end

      def regression_reason(regressions)
        "#{regressions.size} regression(s): " +
          regressions.first(3).map { |r| "#{r.id} (#{r.kind})" }.join(", ")
      end

      def refusal(skill, reason)
        Report.new(candidate_id: skill["name"], passed: false, reason: reason,
                   cases: 0, passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
                   tokens: nil, cached: nil)
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
      rescue StandardError => e
        warn "[harvest] could not delete the gate clone '#{clone_id}': #{e.class}: #{e.message}"
      end
    end
  end
end