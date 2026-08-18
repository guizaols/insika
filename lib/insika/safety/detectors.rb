# frozen_string_literal: true

require_relative "corpus"

module Insika
  module Safety
    # The compiler/matcher over the language-tagged pattern corpus (RFC-0036
    # C2). The pattern SOURCE lives in `Safety::Corpus`; every method here
    # reads a compiled `Corpus::Compiled` set, defaulting to the full shipped
    # corpus — byte-for-byte the runtime's pre-RFC-0036 behavior.
    #
    # Two families live here on purpose — the same lists back BOTH the runtime
    # guardrail AND the eval's `must_not` detectors: the eval
    # is a CLIENT of the runtime by design, so `evals/lib/evals/assertions.rb`
    # requires THIS file rather than keeping a divergent copy. The runtime must never
    # depend on `evals/`, so the file is deliberately self-contained (pure Ruby +
    # frozen regexes, no other Insika require) — it loads standalone from either side.
    #
    #   · OUTPUT side (PII/secret) — patterns that must never reach a customer turn.
    #     Consumed by the OutputFilter (stream redaction) and the eval `pii_leak`.
    #   · INPUT side (injection/abuse/sexual) — high-confidence heuristics that
    #     short-circuit the turn with a safe refusal BEFORE the LLM runs.
    #
    # Everything here is CONSERVATIVE by design (RFC: a false positive blocks a
    # legitimate customer). The deterministic layer catches only the gross,
    # unambiguous cases; the subtler judgment (social engineering, tone) is the LLM
    # moderator's job, not regex.
    #
    # LANGUAGE: the input heuristics are inherently language-specific. We ship pt-BR
    # + EN (the pilot + the OSS lingua franca) as a BEST-EFFORT net; other languages
    # rely on the LLM moderator, which is language-agnostic. A deployment clears a
    # language via `guardrails.corpora` (docs/domain.md) — adding a language is
    # adding data to Corpus, never core changes.
    module Detectors
      module_function

      # The universal open-tail pattern — the prefix of a PII/secret shape
      # that might still be growing. Lives in the corpus data (universal, not
      # language-tagged); kept here for the module's readers.
      OPEN_TAIL = Corpus::OPEN_TAIL

      # Runs a NAMED output detector over `text` -> the matched substring | nil.
      # "pii_leak" = union of all PII patterns; otherwise a single named pattern.
      # Unknown name fails LOUD (a typo'd assertion must never silently pass).
      # `corpus:` — the compiled set for the agent; nil = the full default.
      def detect(name, text, corpus: nil)
        (corpus || Corpus.compile).detect_output(name, text)
      end

      # Names of the PII detectors (for iteration by the eval / config).
      def pii_names(corpus: nil) = (corpus || Corpus.compile).pii.keys

      # [[begin, end), ...] byte-index ranges of every PII/secret match in `text`
      # (used by the OutputFilter to avoid splitting a complete match at a chunk
      # boundary).
      def match_ranges(text, corpus: nil)
        (corpus || Corpus.compile).match_ranges(text)
      end

      # Replaces every PII/secret occurrence with an opaque `[REDACTED:<name>]`
      # marker — the raw value NEVER survives (D "o redigido nunca aparece em
      # claro"). -> [redacted_text, {name => count}].
      def redact(text, corpus: nil)
        (corpus || Corpus.compile).redact(text)
      end

      # Scans a user message against the input heuristics, gated by strictness
      # (see Insika::Safety::Config) and by the agent's compiled corpus.
      # Returns { category:, matched: } for the FIRST category that fires
      # (injection is checked first — the highest-stakes), or nil when the
      # message is clean. `categories` limits which families run.
      #
      #   :injection -> always high confidence
      #   :sexual    -> medium+
      #   :abuse     -> medium+
      def scan_input(text, categories: %i[injection sexual abuse], corpus: nil)
        compiled = corpus || Corpus.compile
        s = text.to_s
        cats = compiled.input_categories(categories)
        return { category: :injection, matched: first_match(compiled.input["injection"], s) } if cats.include?(:injection) && any?(compiled.input["injection"], s)
        return { category: :sexual, matched: first_match(compiled.input["sexual"], s) }        if cats.include?(:sexual) && any?(compiled.input["sexual"], s)
        return { category: :abuse, matched: first_match(compiled.input["abuse"], s) }          if cats.include?(:abuse) && any?(compiled.input["abuse"], s)

        nil
      end

      def any?(patterns, text) = patterns.any? { |re| re.match?(text) }

      def first_match(patterns, text)
        patterns.each { |re| (m = text.match(re)) && (return m[0]) }
        nil
      end
    end
  end
end
