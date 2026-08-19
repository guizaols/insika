# frozen_string_literal: true

require_relative "../coercion"

module Insika
  #   — the pack's deterministic claim extractor + membership check.
  # The pack's DATA (D7): a `sku` regex for the SKU shape. The engine only
  # APPLIES it — it never guesses what a SKU looks like. No NLP, no LLM, no gem.
  #
  # REVIEW-DECISION (rfc-0029 v2): grounding is **SKU-only**. The techspec's
  # name half (name_keys indexing ledger lines to flag names) cannot flag
  # anything: a name found in the text that also came from the ledger is grounded
  # by construction, and detecting a name that matches NO ledger line needs a
  # "this is a product name" signal that does not exist without NLP. It was
  # decorative config that lied — cut, not half-fixed. The ledger keeps ids;
  # `line` stays in the lean envelope for the model's context, it just does not
  # feed the matcher.
  class GroundingMatcher
    # Catastrophic-backtracking cap. A pathological pattern from the pack would
    # otherwise spin the reactor's thread in C — a rescue cannot save a hang, and
    # with_timeout cannot preempt a regex. The final answer is short; 1s is a
    # hard ceiling, not a budget.
    REGEX_TIMEOUT = 1.0

    def initialize(sku: nil)
      @sku = sku && Regexp.new(sku, timeout: REGEX_TIMEOUT) # validated at build; a re-raise here is a bug
    end

    # Is a SKU pattern actually configured? (The doctor's warning and the
    # harvest's D3 refusal ask the same question — a matcher without a sku
    # matches nothing and can verify no claim.)
    def sku? = !@sku.nil?

    # raw (the pack's matcher Hash) -> GroundingMatcher. The `sku` must compile
    # and be length-capped. Raises ValidationError.
    def self.build(raw)
      h = Coercion.deep_stringify(raw || {})
      sku = Coercion.presence(h["sku"])
      if sku
        begin
          Regexp.new(sku)
        rescue RegexpError
          raise Insika::ValidationError, "grounding.matcher.sku does not compile: #{sku.inspect}"
        end
        if sku.bytesize > Grounding::SKU_MAX
          raise Insika::ValidationError, "grounding.matcher.sku exceeds #{Grounding::SKU_MAX} chars"
        end
      end
      new(sku: sku)
    end

    # -> [String] SKU-pattern matches in the text, deduped. Capture-group safe:
    # scans the FULL match (Regexp.last_match(0)), so a pack pattern with groups
    # or alternation can never inject nils or empty captures into the references
    # (a nil claim would corrupt the flag detail and crash the sentence cut).
    def references(text)
      return [] unless @sku

      text.to_enum(:scan, @sku).map { Regexp.last_match(0) }.uniq
    end

    # -> [String] references NOT in the evidence set. The SET is the ledger ids
    # — a claim quoting a ledgered id is grounded; everything else flagged/cut.
    def ungrounded(references, evidence_ids:)
      known = Set.new(evidence_ids.map(&:to_s))
      references.reject { |r| known.include?(r) }
    end
  end
end