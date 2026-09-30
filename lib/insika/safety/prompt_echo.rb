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
    # ignored). Packs carry canned lines the model is meant to repeat ("to return
    # an item, open…"); those are far shorter, so a quote is never an echo.
    module PromptEcho
      WINDOW = 80
      STRIDE = 40
      MIN_ECHO = 400

      module_function

      # -> [text, echoed_chars]. text = the reply up to where the echo starts
      # (trailing whitespace dropped); echoed_chars = 0 when there was none.
      # Everything from the echo on goes: text after a pasted prompt is suspect too.
      def cut(reply, prompt)
        reply = reply.to_s
        haystack = squeeze(prompt.to_s)
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
