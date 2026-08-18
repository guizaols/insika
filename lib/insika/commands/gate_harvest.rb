# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # RFC-0035 C9 — the double gate on ONE candidate (D7 + D6), in order:
    # eval first (expensive — a full golden replay), conversion second (cheap
    # — a fold read). Synchronous control command (the Studio dispatches it;
    # the gate is minutes of real replay, exactly like `gate_refinement`).
    # It records both reports on the candidate and moves it: both passed ->
    # awaiting_approval; either failed -> rejected with the reason (a failed
    # candidate is terminal — the same finding must re-surface with new
    # evidence, no silent retry).
    class GateHarvest
      def initialize(harvest_store:, gate:, conversion_gate:, criterion: nil, event_stream:)
        @harvest_store = harvest_store
        @gate = gate
        @conversion_gate = conversion_gate
        @criterion = criterion
        @event_stream = event_stream
      end

      # payload: { candidate_id: } (tenant from command.meta — WS1)
      # -> Candidate (awaiting_approval | rejected | gated-parked; both
      #    reports attached)
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        candidate_id = AgentPayload.presence(p[:candidate_id])
        raise Insika::ValidationError, "candidate_id is required" if candidate_id.nil?

        candidate = @harvest_store.find_candidate(candidate_id) ||
                    (raise Insika::NotFoundError, "harvest candidate not found: #{candidate_id}")

        # The base graph wires NO gates (the deployment owns the eval surface):
        # the candidate parks at gated with the named reason — refuse-with-a-
        # named-reason, never pass, never crash.
        if @gate.nil? || @conversion_gate.nil?
          parked = @harvest_store.attach_gate(
            candidate.id,
            eval_gate: { "passed" => false, "reason" => "no_eval_gate_wired" },
            conversion_gate: { "passed" => false, "reason" => "no_conversion_gate_wired" },
            criterion_sha: nil
          )
          return parked
        end

        # The mining budget is read HERE too (the review fix): once the mining
        # pass spent the pack's cap, the expensive golden replay is refused
        # with the named reason — the Refinement::Budget discipline ("not
        # gated — the budget was spent"), applied before the provider bill.
        run = @harvest_store.find_run(candidate.run_id)
        cap = run && run.budget && run.budget["tokens"].to_i
        spent = run && run.cost && run.cost["spent"].to_i
        if cap&.positive? && spent.to_i >= cap
          parked = @harvest_store.attach_gate(
            candidate.id,
            eval_gate: { "passed" => false, "reason" => "budget_exceeded",
                         "spent" => spent, "tokens" => cap },
            conversion_gate: { "passed" => false, "reason" => "budget_exceeded" },
            criterion_sha: nil
          )
          return parked
        end

        skill = { "name" => candidate.name, "description" => candidate.description,
                  "body" => candidate.body, "triggers" => candidate.triggers }
        eval_report = @gate.score(agent_id: candidate.agent, skill: skill,
                                  run_id: candidate.run_id)
        conversion_report = @conversion_gate.call(tenant: command.meta[:tenant],
                                                  agent: candidate.agent)
        criterion_sha = @criterion ? @criterion.sha : nil

        # A conversion REFUSAL (missing data — :no_frozen_baseline etc.) is NOT
        # a candidate failure: it parks the candidate at gated with both
        # reports and the named reason — the page shows the ruler's hole.
        # Only a conversion FAILURE (current worse than baseline) rejects.
        if refused?(conversion_report)
          gated = @harvest_store.attach_gate(candidate.id,
                                             eval_gate: eval_report.to_h,
                                             conversion_gate: conversion_report.to_h,
                                             criterion_sha: criterion_sha)
          emit(:harvest_gated, candidate, gated, eval_report, conversion_report)
          return gated
        end

        passed = eval_report.passed && conversion_report.passed
        @harvest_store.attach_gate(candidate.id,
                                   eval_gate: eval_report.to_h,
                                   conversion_gate: conversion_report.to_h,
                                   criterion_sha: criterion_sha)
        result = if passed
                   @harvest_store.mark_awaiting(candidate.id)
                 else
                   reason = eval_report.passed ? conversion_report.reason : eval_report.reason
                   @harvest_store.mark_rejected(candidate.id, operator: "gate", note: reason)
                 end
        emit(:harvest_gated, candidate, result, eval_report, conversion_report)
        result
      end

      private

      # The D6 refusals: the ruler is MISSING, not moving — the candidate
      # parks. Anything else with passed: false is a real failure.
      def refused?(report)
        !report.passed && REFUSAL_REASONS.include?(report.reason)
      end

      REFUSAL_REASONS = %i[no_criterion no_funnel no_frozen_baseline metric_mismatch no_fold
                       baseline_span_short no_baseline_rate budget_exceeded].freeze

      def emit(type, candidate, result, eval_report, conversion_report)
        @event_stream.emit(Insika::Event.new(
                             type: type,
                             # ids and verdicts, never the skill body
                             data: { run_id: candidate.run_id, candidate_id: candidate.id,
                                     agent: candidate.agent,
                                     eval_passed: eval_report.passed,
                                     conversion_passed: conversion_report.passed,
                                     reason: verdict_reason(result, eval_report, conversion_report) },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      # The refusal/failure reason as an id the operator stream can act on —
      # the symbol, not the human note.
      def verdict_reason(result, eval_report, conversion_report)
        return nil if result.status == "awaiting_approval"

        return eval_report.reason unless eval_report.passed
        return conversion_report.reason if conversion_report.reason

        result.decision && result.decision["note"]
      end
    end
  end
end