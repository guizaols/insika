# frozen_string_literal: true

module Insika
  module Refinement
    # What a refinement run is allowed to SPEND (RFC-0013 §3.9, phase D).
    #
    # A panel of 3 proposers over a 7-case golden set is 3 model calls plus 21
    # replayed conversations, each a real turn with real tools. That is the honest
    # objection to the whole feature, and this is the answer to it: a ceiling the
    # operator sets, checked before each expensive step and never in the middle of
    # one. Nothing is aborted mid-flight — a half-scored candidate is worse than an
    # unscored one, because it looks like a verdict.
    #
    # **Unmetered legs are counted, not guessed.** A provider that reports no token
    # usage makes a leg invisible to the ceiling; recording it as 0 would let a budget
    # sit at "0 spent" forever while real money went out, so those legs are tallied
    # separately and shown to the operator. The structural bounds — the fan-out cap on
    # the panel, `max_edits`, the gate's own refusals — are what bound a run whose
    # provider says nothing.
    class Budget
      def initialize(tokens: nil)
        limit = tokens.to_i
        @limit = limit.positive? ? limit : nil
        @spent = 0
        @cached = 0
        @unmetered = 0
      end

      def limited? = !@limit.nil?

      # `tokens` is what the leg SENT, prompt cache included — see
      # `Evals::Runner#billed_tokens` for why the engine's `total_tokens` alone is not
      # that number. `cached` is the part of it that was cached, carried so the record
      # can explain a total rather than just state one. nil/0 tokens = the leg
      # happened and reported nothing.
      def spend(tokens, cached: nil)
        count = tokens.to_i
        if count.positive?
          @spent += count
          @cached += cached.to_i
        else
          @unmetered += 1
        end
        self
      end

      def exhausted? = limited? && @spent >= @limit

      def remaining = limited? ? [@limit - @spent, 0].max : nil

      def to_h = { "tokens" => @limit, "spent" => @spent, "cached" => @cached,
                   "unmetered" => @unmetered }
    end

    # The proposer PANEL (RFC-0013 §3.9 / §3.5): N models write N independent
    # candidates, the gate scores each one by replaying the golden set, and the best
    # SURVIVOR becomes the proposal a human is asked about.
    #
    # Independent, not consensus-seeking. Two models agreeing on wording is weak
    # evidence and a golden case passing is strong evidence (D7), so convergence only
    # ever breaks a tie between candidates the gate already ranked equal.
    #
    # A panel of one is phase C unchanged, which is why there is no second code path:
    # `refinement.proposer` (a single ref) resolves to a one-element panel.
    class Panel
      # One member of the panel: the candidate, WHO wrote it (more than one model when
      # they converged on the identical edit set), and how it scored.
      Entry = Data.define(:candidate, :proposers, :report) do
        def converged = proposers.size
        def passed? = report&.passed == true

        def to_h = { "candidate" => candidate.to_h, "proposers" => proposers,
                     "gate" => report&.to_h }
      end

      Result = Data.define(:entries, :winner, :budget, :failed) do
        def winner_report = winner&.report
      end

      # gate:      a Refinement::Gate (anything answering #score).
      # proposers: [Refinement::Proposer], already resolved by ProposerFactory.panel.
      # budget:    a Budget. The default is unlimited — a deployment that configured
      #            none gets phase C's behaviour, which had no ceiling either.
      def initialize(gate:, proposers: [], budget: Budget.new, fan_out: nil)
        @gate = gate
        @proposers = Array(proposers)
        @budget = budget
        @fan_out = fan_out || Insika::SubagentGraph.fan_out_cap
      end

      # Proposes (unless `raw` is given), builds, gates and ranks. Yields the built
      # entries BEFORE any of them is scored, so the caller can record the panel and
      # move the run to :gating — the gate is the slow part and a run that says
      # nothing until it finishes looks hung.
      #
      # -> Result. Raises ValidationError when there is nothing gateable at all,
      # because that is an operator-facing refusal ("every edit was dropped, here is
      # why"), not a verdict about the agent.
      def run(agent_id:, run_id:, findings:, files:, allowlist:, contents:, limits: {},
              raw: nil, tolerance: nil)
        proposals, failed = raw ? [[raw], []] : propose(agent_id, findings, files, limits)
        # A candidate that ARRIVED (Studio form, API client) cost this run nothing —
        # counting it as an unmetered leg would make the cost record read as if a model
        # had been asked and stayed quiet.
        entries = build(proposals, allowlist, contents, limits, metered: raw.nil?)
        yield entries if block_given?

        scored = entries.map { |entry| score(entry, agent_id, run_id, tolerance) }
        Result.new(entries: scored, winner: self.class.rank(scored), budget: @budget, failed: failed)
      end

      # -> the best SURVIVOR, or nil when none passed.
      #
      # Highest graded score first; ties broken by the fewest edits (a smaller diff is
      # a smaller bet), then by how many proposers converged on it (§3.5). `min_by`
      # over a negated tuple keeps the comparison in one place and stays stable, so
      # two genuinely indistinguishable candidates resolve to the first proposer the
      # operator listed rather than to whichever fiber finished first.
      def self.rank(entries)
        entries.select(&:passed?)
               .min_by { |e| [-e.report.passed_cases, e.candidate.edits.size, -e.converged] }
      end

      # The refusal to RECORD when nothing survived: the entry that got furthest,
      # because "1 regression on `quotes`" tells an operator something and "budget
      # exhausted" tells them only that the run stopped.
      def self.best_refusal(entries)
        entries.find { |e| e.report&.cases.to_i.positive? } ||
          entries.find { |e| e.report } || entries.first
      end

      private

      # All proposers at once, bounded by the RFC-0010 fan-out cap (§3.9 says the
      # panel reuses it). Each is one blocking HTTP call to a provider, so the
      # wall-clock is the slowest model rather than their sum.
      #
      # A proposer that answers prose, times out or 500s takes ITSELF out of the panel
      # and nothing else: the whole point of asking several models is that one of them
      # being useless is a survivable event. All of them failing is not, and raises.
      def propose(agent_id, findings, files, limits)
        raise Insika::ValidationError, "no proposer is configured" if @proposers.empty?

        require_relative "../tools/concurrency"
        blocks = @proposers.map do |proposer|
          lambda do
            proposer.propose(agent_id: agent_id, findings: findings, files: files, limits: limits)
          rescue StandardError => e
            { "failed" => "#{proposer.model}: #{e.class}: #{e.message}" }
          end
        end

        outcomes = Insika::Tools::Concurrency.gather(blocks, max: @fan_out)
        proposals, failures = outcomes.partition { |o| o["failed"].nil? }
        failed = failures.map { |o| o["failed"] }
        if proposals.empty?
          raise Insika::ValidationError,
                "every proposer failed — #{failed.join('; ')}"
        end

        [proposals, failed]
      end

      # Raw candidates -> Entries, DEDUPED by their edit set. Two models that wrote
      # the identical edit are one candidate with two proposers: gating it twice would
      # spend a whole golden replay to learn the same number, and the fact that they
      # agreed is worth more as a tie-break than as a second row.
      def build(proposals, allowlist, contents, limits, metered: true)
        entries = {}
        dropped = []

        proposals.each do |proposal|
          candidate = CandidateBuilder.build(proposal, allowlist: allowlist,
                                                       contents: contents, limits: limits)
          if metered
            raw = proposal.is_a?(Hash) ? proposal : {}
            @budget.spend(raw["tokens"], cached: raw["cached"])
          end
          if candidate.empty?
            dropped.concat(candidate.dropped)
            next
          end

          signature = candidate.edits.map(&:to_h)
          if (seen = entries[signature])
            entries[signature] = seen.with(proposers: seen.proposers + [candidate.proposer])
          else
            entries[signature] = Entry.new(candidate: candidate, proposers: [candidate.proposer],
                                           report: nil)
          end
        end

        return entries.values unless entries.empty?

        # Every edit of every proposal fell off. Say which and why: an operator who
        # gets "invalid candidate" back learns nothing, and a stale `before` is the
        # common one.
        raise Insika::ValidationError,
              "every edit was dropped — #{dropped.map { |d| "#{d.file}: #{d.reason}" }.join('; ')}"
      end

      # One gate run, unless the budget is already spent. An unscored candidate is
      # recorded with a refusal that names the ceiling — never dropped in silence,
      # which would read as "the panel only produced one idea".
      def score(entry, agent_id, run_id, tolerance)
        if @budget.exhausted?
          return entry.with(report: Gate::Report.new(
            candidate_id: entry.candidate.id, passed: false,
            reason: "not gated — the run's token budget (#{@budget.to_h['tokens']}) was spent",
            cases: 0, passed_cases: 0, baseline_cases: 0, regressions: [], report: nil,
            tokens: nil, cached: nil
          ))
        end

        report = @gate.score(agent_id: agent_id, candidate: entry.candidate,
                             run_id: run_id, tolerance: tolerance)
        @budget.spend(report.tokens, cached: report.cached)
        entry.with(report: report)
      end
    end
  end
end
