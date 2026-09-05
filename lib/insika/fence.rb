# frozen_string_literal: true

module Insika
  # Third-party text — a product description, a review, an FAQ body, a fact a
  # customer dictated — reaches the model as bytes, and the model reads every
  # one of them. Those bytes can carry zero-width characters, bidi overrides, a
  # forged "\n\nassistant:" turn marker or a tag shaped like the engine's own
  # transcript markup. This is the ONE sanitizer for that class of input:
  # pure Ruby, stdlib only, no IO, every pattern bounded so a hostile megabyte
  # finishes in linear time on the reactor.
  #
  # It never re-wraps. The engine already renders data inside fixed labels
  # (<memory>, <knowledge>, a tool result) and the FenceNotice provider names
  # them to the model; what this module does is make sure the DATA cannot
  # reproduce those labels or a turn boundary.
  module Fence
    module_function

    # Zero-width, bidi and format controls: the usual carriers of hidden text.
    INVISIBLE = /[\u00AD\u061C\u180E\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\u206A-\u206F\uFE00-\uFE0F\uFEFF\uFFF9-\uFFFB\u{E0000}-\u{E007F}\u{E0100}-\u{E01EF}]/

    # C0/C1 controls except tab, newline and carriage return.
    CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/

    # Tag names that read as transcript or tool-call markup to a model, plus the
    # labels the engine itself renders around data. A copy of any of them inside
    # DATA is a forgery — `<fact>` inside a fact value would end the fact early.
    TAG_NAMES = %w[
      system human user assistant transcript conversation
      tool_result tool_use function_calls function_results invoke
      memory knowledge fact note concept briefing conversation_summary request_context
    ].freeze

    # Only tag-SHAPED text: bare (`<system>`), closing (`</memory>`), self-closing,
    # optionally namespaced (`<ns:invoke>`), with at most eight `name="value"`
    # attributes. Bare words are not attributes, so `<system requirements>`
    # passes. Quantifiers are bounded and non-adjacent — linear on unclosed input.
    TAG_ATTRS = /(?:[ \t]+[\w:.-]{1,40}[ \t]*=[ \t]*(?:"[^"]{0,200}"|'[^']{0,200}'|[^\s"'>]{1,200})){0,8}/
    TAG = /<[ \t]*\/?[ \t]*(?:[a-z][\w.-]{0,30}:)?(?:#{TAG_NAMES.join('|')})\b#{TAG_ATTRS.source}[ \t]*\/?>/i

    # Provider special tokens (`<|im_start|>`, `<|endoftext|>`).
    SPECIAL_TOKEN = /<\|[^|<>\r\n]{1,64}\|>/

    # A forged turn boundary: a blank line (or the very start), a full role word,
    # a colon. A mid-sentence "user:" and a one-letter list marker ("A:") do not
    # match. The colon becomes " -", so the words survive as prose.
    TURN_MARKER = /(\A[ \t]*|(?:\r\n|\r|\n)[ \t]*(?:\r\n|\r|\n)[ \t]*)(human|assistant|system|user)[ \t]*:/i

    REMOVED = "[removed]"
    TRUNCATED = " …[truncated]"
    # One string leaf after the envelope; `Settings fencing.max_chars` overrides.
    DEFAULT_MAX_CHARS = 12_000

    # -> String. `max_chars` bounds the result INCLUDING the suffix.
    def sanitize_text(text, max_chars: nil)
      s = Coercion.utf8(text).unicode_normalize(:nfkc)
      s = s.gsub(INVISIBLE, "").gsub(CONTROL, " ")
      # To a fixpoint: a tag nested inside another (`</memory</memory>>`) must
      # not reassemble once the inner one goes. Each round shrinks the string or
      # stops, so the loop is bounded by the number of tags.
      loop do
        stripped = s.gsub(TAG, REMOVED).gsub(SPECIAL_TOKEN, REMOVED)
        break if stripped == s

        s = stripped
      end
      s = s.gsub(TURN_MARKER) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)} -" }
      cap(s, max_chars)
    end

    # Walks Hash/Array leaves; String leaves are sanitized, keys and every other
    # type pass through untouched (numbers, booleans, nil are not text).
    def sanitize_value(obj, max_chars: nil)
      case obj
      when String then sanitize_text(obj, max_chars: max_chars)
      when Hash then obj.transform_values { |v| sanitize_value(v, max_chars: max_chars) }
      when Array then obj.map { |v| sanitize_value(v, max_chars: max_chars) }
      else obj
      end
    end

    # The per-agent switch, read the same way everywhere (envelope, providers,
    # doctor): an operator's `fencing true`, a form's "1" or a JSON `true`.
    def enabled?(profile)
      profile.respond_to?(:fencing) && Coercion.truthy?(profile.fencing)
    end

    def cap(text, max_chars)
      return text if max_chars.nil? || text.length <= max_chars
      return text[0, max_chars] if max_chars <= TRUNCATED.length

      text[0, max_chars - TRUNCATED.length] + TRUNCATED
    end
    private_class_method :cap
  end
end
