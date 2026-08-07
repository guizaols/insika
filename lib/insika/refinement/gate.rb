# frozen_string_literal: true

module Insika
  module Refinement
    # Scores a candidate by RUNNING it (RFC-0013 §3.5). Not by asking a model whether
    # the edit looks good — that measures nothing, and D3 says so in one line.
    #
    #   1. clone the agent into a throwaway id (`<agent>-cand-<run8>`)
    #   2. copy its instruction files, apply the candidate's edits to the COPY
    #   3. replay the agent's golden set against the clone over the ordinary public
    #      surface (`POST /v1/responses`) — real turns, real tools, real guardrails
    #   4. compare to the accepted baseline; ANY regression disqualifies
    #   5. delete the clone, keep the report
    #
    # Step 3 is what makes this expensive and what makes it worth anything. The gate
    # is the entire safety story of refinement: everything upstream can be wrong —
    # a hallucinated rationale, a model that misread the evidence — and the worst
    # outcome is still a candidate that fails to improve a score and never lands.
    #
    # The clone is deleted in an `ensure`, including when the replay raises. A
    # leftover `-cand-` agent is servable at `/v1/responses` by anyone who knows the
    # id, so leaking one is a real (if obscure) exposure, not just clutter.
    class Gate
      # The verdict for one candidate. `passed` is the only field the caller acts on;
      # the rest is what an operator reads to decide whether the loop earns its keep.
      # `tokens` is what the replay SENT, cache included, as the deployment reported
      # it — nil when no turn carried usage. `cached` is how much of that came from
      # the prompt cache, kept separate because it is what explains one candidate
      # costing 8× another over the same cases. `tokens` is what the panel's budget
      # (§3.9) spends and what the operator reads on the run: a gate is the expensive
      # half of refinement and a loop whose cost is invisible is one nobody can decide
      # to keep.
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

      # transport_factory: -> an Evals transport for the replay. A LAMBDA and not a
      # transport, because the gate is constructed at boot and the deployment's own
      # URL/token are what it has to talk to; passing the built object would freeze a
      # credential the operator can rotate.
      # capabilities_factory: -> an `Evals::HttpCapabilities` for the clone, or nil.
      # Without it a case whose `requires` the agent cannot satisfy RUNS and fails
      # (RFC-0014 §3.2 says it must skip) — and then the gate and `evals/run.rb`, the
      # two callers of the one evaluator, disagree about what the corpus even
      # measures. §3.7 exists to prevent exactly that.
      def initialize(profiles:, agent_files:, goldens:, baselines:, transport_factory:,
                     capabilities_factory: nil, judge_factory: nil, tolerance: DEFAULT_TOLERANCE)
        @profiles = profiles
        @agent_files = agent_files
        @goldens = goldens
        @baselines = baselines
        @transport_factory = transport_factory
        @capabilities_factory = capabilities_factory
        @judge_factory = judge_factory
        @tolerance = tolerance
      end

      # -> Report. Never raises for an ordinary refusal (no cases, no baseline, a
      # replay that blew up): those are verdicts, and a run that recorded WHY it could
      # not gate is more useful than an exception in a log.
      def score(agent_id:, candidate:, run_id:, tolerance: nil)
        cases = @goldens.for_agent(agent_id)
        return refusal(candidate, "the agent has no golden cases — nothing to gate against (RFC-0013 D4)") if cases.empty?

        baseline = @baselines.get(agent_id)
        # Without an accepted state, `Baseline.compare` compares nothing and reports
        # zero regressions — a green light meaning "we did not look". Refusing is the
        # only honest reading, and the fix is one command.
        if baseline.nil?
          return refusal(candidate, "no recorded baseline for '#{agent_id}' — " \
                                    "run `insika evals:baseline import` or record one before gating")
        end

        # And an ALL-RED baseline is the same hole with a record in front of it.
        # `compare` only reports a regression against a case the baseline had
        # PASSING, so a baseline where nothing passes cannot produce one: every
        # candidate sails through, including a harmful one.
        #
        # Found by running this against a real agent: a replay that 401'd recorded a
        # baseline of two failures, and from then on the gate accepted everything —
        # including an edit written to be harmful. "Known-failing cases do not wedge
        # the gate" is the right rule for the pre-merge check (a red case is work in
        # progress, not a blocker); here it degrades into "nothing can ever fail",
        # and a gate that cannot fail is not a gate.
        if passing_cases(baseline).zero?
          return refusal(candidate, "the recorded baseline for '#{agent_id}' has no PASSING case " \
                                    "(#{baseline_size(baseline)} recorded, all failing) — nothing could " \
                                    "regress, so every candidate would pass. Fix the agent or the cases, " \
                                    "then re-record the baseline from a green run")
        end

        # And a baseline JUDGED by a rubric, replayed with no judge, is the third
        # shape of the same hole — the one this gate actually shipped with.
        #
        # `CaseResult#pass?` reads a missing judge verdict as a pass (a rubric'd case
        # is `judge_pending?`, which nothing consults), so a replay with no judge
        # scores every rubric case as passing. Compared against a baseline recorded
        # WITH a judge, that is not a weaker measurement, it is an inverted one:
        # every candidate reads as an improvement.
        #
        # Measured, not reasoned: gating the real pilot agent with `settings["evals"]`
        # unset reported **6/6, no regression** against a baseline the same corpus had
        # just scored **2/6** — `produto-sem-cep` was judged 0.0 and "passed". Both
        # candidates on the panel cleared. That is §3.7's failure exactly: the CLI and
        # the gate, the two callers of the one evaluator, disagreeing about what the
        # corpus measures.
        judge = @judge_factory&.call
        if judge.nil? && judged?(baseline)
          return refusal(candidate, "the recorded baseline for '#{agent_id}' carries judge scores but no " \
                                    "judge is configured — a rubric'd case with no verdict counts as a " \
                                    "PASS, so every candidate would beat it. Configure the judge panel " \
                                    "(Studio → Settings → Evals, or `settings[\"evals\"][\"judges\"]`) or " \
                                    "re-record the baseline without one")
        end

        clone_id = clone_id_for(agent_id, run_id)
        begin
          build_clone(agent_id, clone_id, candidate)
          ran = replay(cases, clone_id, judge)
          verdict(candidate, ran, baseline, tolerance || @tolerance)
        rescue StandardError => e
          refusal(candidate, "gate failed to run: #{e.class}: #{e.message}")
        ensure
          destroy_clone(clone_id)
        end
      end

      # `<agent>-cand-<run8>`: recognizable at a glance in the Studio's agent list and
      # in a provider bill, and scoped to the run so two gates cannot collide.
      def clone_id_for(agent_id, run_id) = "#{agent_id}-cand-#{run_id.to_s.delete('-')[0, 8]}"

      # How many accepted cases could actually regress. This is the gate's real
      # strength, and it is worth being able to say out loud.
      def passing_cases(baseline)
        (baseline["cases"] || {}).count { |_id, entry| entry.is_a?(Hash) && entry["pass"] }
      end

      # Was this baseline recorded with a judge? A single scored case is enough: it
      # proves the accepted state was measured by a rubric the replay has to match.
      # A baseline with no scores at all was recorded blind too, so both sides are
      # equally deterministic and the comparison, while weak, is not inverted.
      def judged?(baseline)
        (baseline["cases"] || {}).any? { |_id, entry| entry.is_a?(Hash) && !entry["score"].nil? }
      end

      private

      def baseline_size(baseline) = (baseline["cases"] || {}).size

      # Same profile, same tools, same guardrails — only the id and the instruction
      # files differ. Copying the profile rather than editing the real one is what
      # makes this safe to run against production: the live agent is never touched,
      # not even for a moment.
      def build_clone(agent_id, clone_id, candidate)
        profile = @profiles.fetch(agent_id) ||
                  (raise Insika::NotFoundError, "agent '#{agent_id}' not configured")
        @profiles.put(profile.with(id: clone_id))

        contents = current_files(agent_id)
        edited = candidate.apply(contents)
        contents.merge(edited).each { |name, body| @agent_files.write(clone_id, name, body) }
      end

      # Every file the agent has, not only the ones the candidate touches: the clone
      # has to be the same agent for the replay to mean anything.
      def current_files(agent_id)
        @agent_files.list(agent_id).each_with_object({}) do |name, acc|
          acc[name] = @agent_files.read(agent_id, name).to_s
        end
      end

      # The goldens name the REAL agent; the replay has to address the clone. The
      # case is otherwise untouched — same turns, same rubric, same assertions — so
      # what is measured is the edit and nothing else.
      #
      # The RunCases are kept whole (not `.map(&:result)`) because the token counts
      # ride on them, and the budget is only honest if it sees what the replay spent.
      def replay(cases, clone_id, judge)
        retargeted = cases.map { |g| g.class.new(**g.to_h.merge(agent: clone_id)) }
        runner = Insika::Evals::Runner.new(transport: @transport_factory.call, judge: judge,
                                           capabilities: @capabilities_factory&.call)
        runner.run(retargeted)
      end

      def verdict(candidate, ran, baseline, tolerance)
        results = ran.map(&:result)
        regressions = Insika::Evals::Baseline.compare(results, baseline, tolerance: tolerance)
        passed = results.count(&:pass?)
        graded = results.reject(&:skipped?).size
        spent = ran.filter_map(&:tokens)
        cached = ran.filter_map(&:cached)

        Report.new(
          candidate_id: candidate.id, passed: regressions.empty?,
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

      def refusal(candidate, reason)
        Report.new(candidate_id: candidate.id, passed: false, reason: reason,
                   cases: 0, passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
                   tokens: nil, cached: nil)
      end

      # Both halves, both tolerant of a missing one: this runs in an `ensure` after a
      # failure that may have happened before either was created.
      def destroy_clone(clone_id)
        @agent_files.list(clone_id).each { |name| @agent_files.delete(clone_id, name) }
        @profiles.delete(clone_id)
      rescue StandardError => e
        warn "[refinement] could not delete the gate clone '#{clone_id}': #{e.class}: #{e.message}"
      end
    end
  end
end
