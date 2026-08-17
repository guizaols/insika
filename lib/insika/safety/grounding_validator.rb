# frozen_string_literal: true

module Insika
  module Safety
    # RFC-0029 C7 — the `:flag` half of grounding. A reply claiming a product
    # whose reference is not in the evidence ledger is FLAGGED (audit via the
    # existing `:guardrail_flagged` channel) — the text is already out, so
    # flagging is audit, exactly like every other output flag.
    #
    # Runs as the FIRST step of the OutputValidator's after_task chain, BEFORE
    # the `config.output` gate (D9): grounding is evidence integrity, independent
    # of the guardrails opt-in — an agent with guardrails off and
    # `grounding.mode: :flag` still gets the check. Fail-open on any error
    # (grounding must never break a completed turn).
    class GroundingValidator
      # -> state (the after_task contract). Appends `:ungrounded` flags.
      def call(state)
        grounding = grounding_of(state)
        # :flag only — :enforce is the enforcer's job, :off / absent is nothing.
        return state if grounding.nil? || grounding.off? || grounding.enforce?

        ledger = state.respond_to?(:evidence_ledger) ? state.evidence_ledger : nil
        return state unless ledger

        text = state.response_content.to_s
        return state if text.empty?

        refs = grounding.matcher.references(text)
        claims = grounding.matcher.ungrounded(refs, evidence_ids: ledger.ids)
        claims.each { |c| ledger.ungrounded_count(c) }
        unless claims.empty?
          state.guardrail_flags = Array(state.guardrail_flags) + [{
            category: "ungrounded", source: "evidence",
            detail: "product claim without tool evidence: #{claims.join(', ')}" }]
        end
        state
      rescue StandardError
        state # fail-open
      end

      private

      def grounding_of(state)
        raw = state.profile.respond_to?(:grounding) ? state.profile.grounding : nil
        raw && Insika::Grounding.parse(raw)
      end
    end
  end
end
