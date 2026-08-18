# frozen_string_literal: true

module Insika
  module Safety
    # The SHIPPED deterministic guardrail corpus as language-tagged DATA
    # (RFC-0036 C2/D2). Pure data — no Insika requires, standalone-loadable
    # like detectors.rb used to be.
    #
    # Pattern SOURCE now lives here; `Detectors` is the compiler/matcher on
    # top. The runtime compiles a per-agent `Compiled` set — a deployment
    # clears the pt-BR families via `guardrails.corpora.languages` and extends
    # them via `guardrails.corpora.extra` (docs/domain.md). Absent config = the
    # full shipped default: byte-for-byte today's behavior (parity).
    #
    # LANGUAGE: each regex lives in exactly ONE language. `compile` (no args)
    # is the union of the shipped languages, each family in its shipped order.
    # For a single-language input the default behaves exactly as the runtime
    # that hard-coded one flat list — the ONE honest delta: the pre-RFC flat
    # list INTERLEAVED the languages, so for a phrase matching patterns of
    # BOTH languages the reported `matched` substring may differ (the
    # category never does). Pinned in spec/insika/safety/corpus_spec.rb.
    module Corpus
      # ── The shipped input families ─────────────────────────────────────────
      # "injection"/"sexual"/"abuse" per language. High-confidence heuristics
      # that short-circuit the turn BEFORE the LLM runs (conservative by
      # design — a false positive blocks a legitimate customer; the subtler
      # judgment is the LLM moderator's).
      DEFAULTS = {
        "pt-BR" => {
          "injection" => [
            /\binstru[çc][õo]es\s+de\s+sistema\b/i,
            /\b(regras|instru[çc][õo]es|orienta[çc][õo]es|diretrizes)\s+internas\b/i,
            /\b(revele|mostre|exiba|me\s+(d[êe]|mande|envie|passe)|repita|imprima)\b[^.?!]{0,40}\b(prompt|instru[çc][õo]es|regras|configura[çc][ãa]o|system)\b/i,
            # "ignore/disregard the (previous) instructions"
            /\b(ignore|ignora|desconsidere|esque[çc]a)\b[^.?!]{0,30}\b(instru[çc][õo]es|regras|orienta[çc][õo]es|acima|anteriores)\b/i,
            # encode/translate the prompt (the base64/rot13 exfil trick, either order)
            /\b(base64|rot13|codific|encode|cifr)\w*\b[^.?!]{0,60}\b(instru[çc][õo]es|prompt|regras|sistema|system)\b/i,
            /\b(instru[çc][õo]es|prompt|regras|sistema|system)\b[^.?!]{0,60}\b(base64|rot13|codific|encode|cifr)\w*\b/i
          ],
          "sexual" => [
            /\b(nudes?|pelad[oa]s?|s?exo|transar|transa\b|gozar|tes[ãa]o|s[ãa]fad[oa]|puta|pau|buceta|piroca|caralho\s+(duro|na))\b/i,
            /\bo\s+que\s+voc[êe]\s+faria\s+comigo\b/i,
            /\b(descrev|imagina|conta)\w*\b[^.?!]{0,30}\bcomigo\s+(na\s+cama|pelad)/i,
            /\b(quer|vamos)\b[^.?!]{0,20}\b(transar|fazer\s+sexo|sexo)\b/i
          ],
          "abuse" => [
            # Directed insult only — "a entrega foi uma merda" must NOT block;
            # "você é uma merda de atendente" should. The `você é …` anchor
            # keeps precision high.
            /\bvoc[êe]\s+(é|e|ta|est[áa])\b[^.?!]{0,25}\b(lixo|in[uú]til|merda|imprest[aá]vel|idiota|burr[oa]|est[uú]pid[oa]|otári[oa]|in[uú]teis|incompetente|p[áa]ssim[oa])\b/i,
            /\b(seu|sua)\s+(lixo|in[uú]til|idiota|imbecil|otári[oa]|burr[oa]|est[uú]pid[oa]|merda|escrot[oa])\b/i,
            /\bvai\s+(se\s+)?(fuder|foder|tomar\s+no)\b/i
          ]
        },
        "en" => {
          "injection" => [
            /\bsystem\s*prompt\b/i,
            /\b(ignore|disregard|forget)\b[^.?!]{0,30}\b(instructions|rules|prompt|above|previous|prior)\b/i
          ],
          "sexual" => [
            /\b(horny|blow\s?job|hand\s?job|jerk\s+off|have\s+sex|send\s+(me\s+)?(a\s+)?nudes?|dick\s+pic)\b/i,
            /\bwhat\s+(would|will)\s+you\s+do\s+to\s+me\b/i
          ],
          "abuse" => [
            # Directed insult only (keeps precision high; frustration ≠ abuse)
            /\byou\s*(?:'?re|\s+are)\b[^.?!]{0,25}\b(useless|garbage|trash|idiot|stupid|worthless|pathetic|incompetent|dumb|a\s+joke)\b/i,
            /\b(fuck|screw)\s+you\b/i,
            /\byou\s+(suck|are\s+the\s+worst)\b/i
          ]
        }
      }.freeze

      # ── The shipped OUTPUT detectors (PII/secret redaction targets) ────────
      # Language-tagged: "secret" is universal (never cleared); "cpf"/"cnpj"
      # are pt-BR tax-id formats — an EN-only corpus drops them (documented
      # consequence, docs/domain.md). Key ORDER is the pre-RFC runtime's
      # (cpf, cnpj, secret) — it is what `pii_names` and the "pii_leak" union
      # iterate.
      PII = {
        "cpf" => {
          "languages" => ["pt-BR"],
          "pattern" => /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/
        },
        "cnpj" => {
          "languages" => ["pt-BR"],
          "pattern" => /\b\d{2}\.\d{3}\.\d{3}\/\d{4}-\d{2}\b/
        },
        "secret" => {
          "languages" => nil,
          "pattern" => /\b(?:sk-[A-Za-z0-9]{16,}|Bearer\s+[A-Za-z0-9._-]{16,})\b/
        }
      }.freeze

      # A run of the output stream that MIGHT still be growing into a
      # PII/secret match if more chunks arrive — anchored at the buffer tail
      # (the OutputFilter's hold-back). Universal: it covers the unbounded
      # `sk-…`/`Bearer …` shapes and the in-progress CPF/CNPJ digit runs.
      OPEN_TAIL = %r{
        (?:
          s(?:k(?:-[A-Za-z0-9]*)?)?                    # prefix of "sk-" + optional body
          | B(?:e(?:a(?:r(?:e(?:r(?:\s+[A-Za-z0-9._-]*)?)?)?)?)?)?  # prefix of "Bearer " + body
          | \d[\d./-]*                                 # in-progress CPF/CNPJ digit run
        )\z
      }x

      # The compiled corpus for ONE agent: the input families + output
      # detectors filtered by its languages and extended by its `extra`
      # patterns. Immutable (Data + deep-frozen collections) and shared safely.
      Compiled = Data.define(:languages, :input, :pii) do
        # The subset of `categories` (symbols) that have patterns in this
        # corpus — the strictness gate applied to the compiled set.
        def input_categories(categories)
          categories.select { |cat| Array(input[cat.to_s]).any? }
        end

        # Runs a NAMED output detector over `text` -> the matched substring |
        # nil. "pii_leak" = union of all patterns; an entirely UNKNOWN name
        # fails LOUD (a typo'd assertion must never silently pass); a name the
        # corpus knows but whose language was cleared matches nothing.
        def detect_output(name, text)
          patterns =
            if name.to_s == "pii_leak"
              pii.values
            else
              p = pii[name.to_s]
              if p.nil? && !Corpus::PII.key?(name.to_s)
                raise ArgumentError, "unknown detector: #{name.inspect}"
              end

              p ? [p] : []
            end
          patterns.each { |re| (m = text.to_s.match(re)) && (return m[0]) }
          nil
        end

        # Replaces every PII/secret occurrence with an opaque `[REDACTED:<name>]`
        # marker — the raw value NEVER survives. -> [redacted_text, {name => count}].
        def redact(text)
          counts = Hash.new(0)
          out = text.to_s.dup
          pii.each do |name, re|
            out = out.gsub(re) do
              counts[name] += 1
              "[REDACTED:#{name}]"
            end
          end
          [out, counts]
        end

        # [[begin, end), ...] byte-index ranges of every PII/secret match in
        # `text` (used by the OutputFilter to avoid splitting a complete match
        # at a chunk boundary).
        def match_ranges(text)
          ranges = []
          pii.each_value do |re|
            text.to_s.scan(re) { ranges << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
          end
          ranges
        end

        # The universal open-tail pattern (see Corpus::OPEN_TAIL).
        def open_tail = Corpus::OPEN_TAIL
      end

      KNOWN_FAMILIES = %w[injection sexual abuse].freeze

      # -> Compiled. `languages`: nil = ALL shipped languages (parity default);
      # [] = no shipped input family (only `extra`); ["en"] = the EN-only
      # corpus. `extra`: { "abuse" => ["/\\bdupa\\b/i", ...] } — per-category
      # additions in the source-string syntax (or Regexp objects), compiled
      # with the same syntax. Raises Insika::ValidationError naming the value
      # for an unknown language/family or a malformed pattern.
      #
      # Compiled values are immutable, so the result is MEMOIZED per signature:
      # a turn builds Config several times (input middleware, output validator,
      # filter factory) and each build must not re-compile the same patterns.
      def self.compile(languages: nil, extra: {})
        key = [languages.is_a?(Array) ? languages.sort : languages, extra]
        @cache ||= {}
        @cache[key] ||= build(languages, extra)
      end

      def self.build(languages, extra)
        langs = languages.nil? ? DEFAULTS.keys : validate_languages!(languages)
        extra = validate_extra!(extra)

        input = {}
        langs.each do |lang|
          DEFAULTS.fetch(lang).each do |cat, patterns|
            input[cat] = Array(input[cat]) + patterns
          end
        end
        extra.each do |cat, sources|
          input[cat.to_s] = Array(input[cat.to_s]) + Array(sources).map { |src| compile_pattern(src, cat) }
        end

        pii = {}
        PII.each do |name, meta|
          meta_langs = meta["languages"]
          next if meta_langs && (meta_langs & langs).empty?

          pii[name] = meta["pattern"]
        end

        # `langs.dup`: the caller's array is never frozen out from under it.
        Compiled.new(
          languages: langs.dup.freeze,
          input: input.transform_values(&:freeze).freeze,
          pii: pii.freeze
        )
      end
      private_class_method :build

      def self.validate_languages!(languages)
        unless languages.is_a?(Array) && (languages - DEFAULTS.keys).empty?
          raise Insika::ValidationError,
                "guardrails.corpora.languages must be an Array of known languages " \
                "(#{DEFAULTS.keys.join(", ")}), got: #{languages.inspect}"
        end
        languages
      end

      def self.validate_extra!(extra)
        unless extra.is_a?(Hash) && (extra.keys.map(&:to_s) - KNOWN_FAMILIES).empty?
          unknown = extra.is_a?(Hash) ? extra.keys.map(&:to_s) - KNOWN_FAMILIES : []
          label = unknown.empty? ? extra.inspect : unknown.join(", ")
          raise Insika::ValidationError,
                "guardrails.corpora.extra must be a Hash with known families " \
                "(#{KNOWN_FAMILIES.join(", ")}), got: #{label}"
        end
        extra
      end

      # A pattern source -> Regexp. Accepts the source-string syntax
      # ("/\\bdupa\\b/i") or a bare pattern; Regexp objects pass through.
      # A malformed source fails with the pattern named.
      def self.compile_pattern(source, family)
        return source if source.is_a?(Regexp)

        s = source.to_s
        if (m = s.match(%r{\A/(.*)/([a-z]*)\z}m))
          Regexp.new(m[1], m[2])
        else
          Regexp.new(s)
        end
      rescue RegexpError => e
        raise Insika::ValidationError,
              "guardrails.corpora.extra.#{family}: invalid pattern source " \
              "#{source.inspect} (#{e.message})"
      end

      private_class_method :validate_languages!, :validate_extra!, :compile_pattern
    end
  end
end
