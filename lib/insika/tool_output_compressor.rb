# frozen_string_literal: true

require "digest"

module Insika
  # Mechanical (no-LLM) compression of tool output in the replayed transcript
  # (A3/C3, hermes phase 1): identical tool results are stored ONCE — the first
  # occurrence full — and every byte-identical repeat is replaced with a compact
  # back-reference to it plus the original's first line. The cheap half of
  # compaction: a search tool that returns the same catalog page over N turns
  # currently pays for the full body N times, and that accumulation is what
  # blows the budget first.
  #
  # Deliberately crude on purpose: SHA-256 digest, so ONLY exact matches dedupe —
  # a differing detail is kept, never "close enough" dropped. Deterministic per
  # input (the same transcript compresses identically every turn, prompt-cache
  # friendly). Never touches user/assistant content and never mutates the input
  # (symbol or string keys are preserved per message).
  #
  # Consumer: the history path of Context::Providers::Session, opt-in via
  # AgentProfile#tool_output_compression. The LLM half of compaction (real
  # summarization) remains F5 — decided with data, not by matrix.
  class ToolOutputCompressor
    # Below this a back-reference can never cost less than the body it
    # replaces (an early bail; the REAL gate is the length check per repeat).
    MIN_LENGTH = 200
    # The mechanical "1-line summary": the original's first line, capped here
    # (160 chars ≈ ~40 tokens — a bounded, informative stub).
    SUMMARY_LIMIT = 160

    # The boilerplate deliberately carries NO positional pointer ("see above"):
    # the budget cut evicts the OLDEST unit first, which is the original this
    # back-reference points at — a "↑" that survives its target leaves a dangle
    # in the model's context (C3). The summary is the content; it stands alone.
    BOILERPLATE = "[repeated tool output — byte-identical to an earlier result " \
                  "in this conversation; One-line summary: "

    class << self
      # [message, ...] with repeated tool results back-referenced. A non-tool
      # message or a tool result that is not a String passes through untouched.
      # A repeat is replaced ONLY when the back-reference is strictly shorter
      # than the content it would replace (in the 200–~260-char band a
      # back-reference is LONGER than the original — replacing there would
      # GROW the transcript, C3).
      def compress_transcript(messages)
        seen = {}
        Array(messages).map do |m|
          content = text_of(m)
          next m unless content && content.length >= MIN_LENGTH

          digest = Digest::SHA256.hexdigest(content)
          if seen.key?(digest)
            replacement = back_reference(seen[digest][:summary])
            replacement.length < content.length ? replace_content(m, replacement) : m
          else
            seen[digest] = { summary: summarize(content) }
            m
          end
        end
      end

      private

      # -> String | nil: the content of a role:tool message, nil otherwise
      # (compression is for tool RESULTS only; a person's words are never touched).
      def text_of(m)
        return nil unless m.is_a?(Hash)
        return nil unless (m[:role] || m["role"]).to_s == "tool"

        c = m[:content] || m["content"]
        c.is_a?(String) ? c : nil
      end

      def back_reference(summary)
        "#{BOILERPLATE}#{summary}]"
      end

      # A dup with the content replaced under the SAME key style as the original
      # (symbol-keyed message -> symbol content, string-keyed -> string content).
      def replace_content(m, text)
        out = m.dup
        if m.key?(:content)
          out[:content] = text
        else
          out["content"] = text
        end
        out
      end

      # The mechanical one-line summary: the first line, whitespace-collapsed and
      # capped. For a multi-line JSON tool body the first line is a real head; for
      # a single-line blob it is a truncated head — never the whole body.
      def summarize(content)
        first = content.to_s.split(/\r?\n/).first.to_s
        collapsed = first.gsub(/\s+/, " ").strip
        collapsed.length <= SUMMARY_LIMIT ? collapsed : "#{collapsed[0, SUMMARY_LIMIT]}…"
      end
    end
  end
end