# frozen_string_literal: true

module Insika
  # RFC-0027 C3 — pure: confirmed answer text -> the balloons a progressive
  # channel should POST. Paragraphs are the unit (`\n\n` is the seam E1 cares
  # about); the sentence split fires only as a SOFT cap for one paragraph that
  # grew past `SENTENCE_AFTER`. It never splits inside a fenced code block.
  #
  # No events, no outbox, no `:intermediate` — if it is handed loop narration
  # that is a caller bug; the splitter has no way to tell.
  module BalloonSplitter
    # Soft cap after which a single paragraph is split on sentences. WhatsApp's
    # hard cap is ~4096; this is a readability cap, not a platform one.
    SENTENCE_AFTER = 600

    module_function

    # -> [String], at least one when `text` is non-blank, else [].
    def split(text)
      raw = Insika::Coercion.presence(text)
      return [] if raw.nil?

      paragraphs = raw.split(PARAGRAPH_BREAK)
      balloons = group_fenced(paragraphs)
      balloons.flat_map { |balloon| split_long(balloon) }
    end

    # A fenced code block (` ``` ` … ` ``` `) spans paragraphs and stays ONE
    # balloon — newlines inside it are code, not a seam. A fence that never
    # closes still ends as one balloon (garbage in, one balloon out).
    def group_fenced(paragraphs)
      balloons = []
      fence = nil
      paragraphs.each do |para|
        piece = para.strip
        next if piece.empty?

        if fence
          fence << piece
          # a line starting with ``` closes the block opened the same way
          balloons << fence.join("\n\n") if piece.start_with?(FENCE)
          fence = nil if piece.start_with?(FENCE)
        elsif piece.start_with?(FENCE)
          fence = [piece]
        else
          balloons << piece
        end
      end
      balloons << fence.join("\n\n") if fence
      balloons
    end

    # The soft cap: a paragraph longer than SENTENCE_AFTER splits after sentence
    # closers followed by whitespace — which is why `3.9s` and `www.` survive
    # (their period is not followed by whitespace) and a decimal does too. A
    # leftover without a closer stays one balloon.
    def split_long(balloon)
      return [balloon] if balloon.length <= SENTENCE_AFTER

      parts = balloon.split(SENTENCE_BOUNDARY).map(&:strip).reject(&:empty?)
      parts.empty? ? [balloon] : parts
    end

    PARAGRAPH_BREAK = /\n\s*\n+/
    FENCE = "```"
    SENTENCE_BOUNDARY = /(?<=[.!?…])\s+(?=\S)/
    private_constant :PARAGRAPH_BREAK, :FENCE, :SENTENCE_BOUNDARY
  end
end