# frozen_string_literal: true

module Insika
  module Safety
    # The model pasting its own system prompt into the answer: a real reply, then
    # the whole prompt — tool names, internal tags — in the same message. Rare, but
    # the deterministic output tier only knows PII and the LLM validator is opt-in,
    # so nothing caught it. This check is deterministic and costs a few substring
    # searches, so it runs on every turn.
    #
    # An echo is a LONG verbatim run of the prompt (MIN_ECHO chars, whitespace
    # ignored). Packs also carry canned text the model is meant to repeat word for
    # word, and some of it is longer than MIN_ECHO. The engine cannot tell that text
    # from an internal rule by its formatting (packs use quotes and lists for both),
    # so the operator lists it: `guardrails.echo_allow`, exact texts. Those texts are
    # taken out of the prompt before comparing, so repeating one is never an echo,
    # while the rest of the prompt stays protected at the same MIN_ECHO.
    module PromptEcho
      WINDOW = 80
      STRIDE = 40
      MIN_ECHO = 400
      # Squeezed prompts kept, keyed by the prompt text and the allow list: an
      # agent's prompt is the same on every turn, so squeezing it again per reply
      # was wasted work.
      CACHE_MAX = 64
      SQUEEZED = {}

      module_function

      # -> [text, echoed_chars]. text = the reply up to where the echo starts
      # (trailing whitespace dropped); echoed_chars = 0 when there was none.
      # Everything from the echo on goes: text after a pasted prompt is suspect too.
      # `allow` = canned texts the agent may repeat (guardrails.echo_allow).
      def cut(reply, prompt, allow: [])
        reply = reply.to_s
        return [reply, 0] if reply.size < MIN_ECHO # squeezing never lengthens it

        haystack = squeezed_prompt(prompt.to_s, allow)
        return [reply, 0] if haystack.size < MIN_ECHO

        norm, map = squeeze_with_map(reply)
        at = echo_start(norm, haystack)
        return [reply, 0] if at.nil?

        from = map[at]
        [reply[0...from].rstrip, reply.size - from]
      end

      # Index in `norm` where a run of at least MIN_ECHO chars of `haystack` starts.
      def echo_start(norm, haystack)
        seen = ->(i) { i >= 0 && i + WINDOW <= norm.size && haystack.include?(norm[i, WINDOW]) }
        i = 0
        while i + WINDOW <= norm.size
          if seen.(i)
            start = i
            start -= 1 while start > i - STRIDE && seen.(start - 1)
            stop = i
            stop += STRIDE while seen.(stop + STRIDE)
            return start if stop + WINDOW - start >= MIN_ECHO

            i = stop
          end
          i += STRIDE
        end
        nil
      end

      def squeeze(text) = text.gsub(/\s+/, " ")

      # Plain Hash, cleared when full: a miss only costs the squeeze again.
      def squeezed_prompt(prompt, allow = [])
        SQUEEZED.fetch([prompt, allow]) do
          SQUEEZED.clear if SQUEEZED.size >= CACHE_MAX
          SQUEEZED[[prompt, allow]] = without_allowed(squeeze(prompt), allow)
        end
      end

      # Each allowed text is cut out of the squeezed prompt (a literal match, never a
      # pattern). The "\n" left in its place never appears in a squeezed reply, so no
      # run can bridge across it.
      def without_allowed(haystack, allow)
        allow.reduce(haystack) do |acc, text|
          canned = squeeze(text.to_s).strip
          canned.empty? ? acc : acc.gsub(canned, "\n")
        end
      end

      # The squeezed text plus, for each of its chars, the index in the original.
      def squeeze_with_map(text)
        norm = +""
        map = []
        text.each_char.with_index do |ch, idx|
          if ch.match?(/\s/)
            next if norm.end_with?(" ")

            ch = " "
          end
          norm << ch
          map << idx
        end
        [norm, map]
      end
    end
  end
end
