# frozen_string_literal: true

module Insika
  module Safety
    # RFC-0029 C7/D6 — the `:enforce` half of grounding: the claim's SENTENCE is
    # cut from the content the turn persists and delivers. A NEW stage-8 boundary
    # step (a plain executor call, NOT an after_task hook — after_task fires too
    # late to change what is persisted).
    #
    # The cut removes the SENTENCE that contains an ungrounded claim (never a
    # surgical span — removing half a sentence produces broken prose). What the
    # cut CANNOT do is unsay a streamed delta — for a streaming surface `:enforce`
    # still delivers the cut text via channel delivery and flags the turn; that
    # honesty is why the RFC's own default is `:flag` (ship `:enforce` only after
    # the matcher audit). Runs ONLY in :enforce mode — inert otherwise.
    class GroundingEnforcer
      # -> [new_content, state]. The stage-8 boundary call. Fail-open: grounding
      # must never break a completed turn.
      def call(task, state, content)
        grounding = grounding_of(state)
        return [content, state] unless grounding&.enforce?

        ledger = state.respond_to?(:evidence_ledger) ? state.evidence_ledger : nil
        return [content, state] unless ledger

        text = content.to_s
        refs = grounding.matcher.references(text)
        claims = grounding.matcher.ungrounded(refs, evidence_ids: ledger.ids)
        return [content, state] if claims.empty?

        cut = cut_sentences(text, claims)
        claims.each { |c| ledger.ungrounded_count(c) }
        state.guardrail_flags = Array(state.guardrail_flags) + [{
          category: "ungrounded", source: "evidence", action: "cut",
          detail: "cut claim(s): #{claims.join(', ')}" }]
        [cut, state]
      rescue StandardError
        [content, state] # fail-open: grounding must never break a completed turn
      end

      private

      def grounding_of(state)
        raw = state.profile.respond_to?(:grounding) ? state.profile.grounding : nil
        raw && Insika::Grounding.parse(raw)
      end

      # The smallest self-contained unit: split on sentence boundaries and drop
      # every sentence containing an ungrounded reference. Conservative on
      # purpose — a sentence with TWO claims, one grounded and one not, is cut
      # whole (documented behavior).
      def cut_sentences(text, claims)
        sentences = text.split(/(?<=[.!?])\s+/)
        kept = sentences.reject { |sentence| claims.any? { |claim| sentence.include?(claim) } }
        kept.join(" ").strip
      end
    end
  end
end
