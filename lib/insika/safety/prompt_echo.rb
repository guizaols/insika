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
    # word, and some of it is longer than MIN_ECHO. A pack marks that text as a
    # quote: lines starting with `>` (after any indentation). Those lines are left
    # out of the text compared, so repeating them is never an echo, while the rest
    # of the prompt stays protected at the same MIN_ECHO.
    module PromptEcho
      WINDOW = 80
      STRIDE = 40
      MIN_ECHO = 400
      # Squeezed prompts kept, keyed by the prompt text: an agent's prompt is the
      # same on every turn, so squeezing it again per reply was wasted work.
      CACHE_MAX = 64
      SQUEEZED = {}

      module_function

      # -> [text, echoed_chars]. text = the reply up to where the echo starts
      # (trailing whitespace dropped); echoed_chars = 0 when there was none.
      # Everything from the echo on goes: text after a pasted prompt is suspect too.
      def cut(reply, prompt)
        reply = reply.to_s
        return [reply, 0] if reply.size < MIN_ECHO # squeezing never lengthens it

        haystack = squeezed_prompt(prompt.to_s)
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
      # Quote lines (`> …`) are dropped first: they are what the pack wants said.
      def squeezed_prompt(prompt)
        SQUEEZED.fetch(prompt) do
          SQUEEZED.clear if SQUEEZED.size >= CACHE_MAX
          SQUEEZED[prompt] = squeeze(without_quotes(prompt))
        end
      end

      def without_quotes(prompt) = prompt.each_line.reject { |line| line.lstrip.start_with?(">") }.join

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
