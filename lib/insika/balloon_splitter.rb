# frozen_string_literal: true

module Insika
  #   — pure: confirmed answer text -> the balloons a progressive
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
          # a line starting with ``` closes the block, wherever it lands — the
          # close fence of ordinary markdown shares a paragraph with its code.
          if closes_fence?(piece)
            balloons << fence.join("\n\n")
            fence = nil
          end
        elsif piece.lines.first.to_s.start_with?(FENCE)
          fence = [piece]
          # one paragraph may open AND close the block (```ruby\nx = 1\n```) —
          # the closer is a later line of the same piece.
          if closes_fence?(piece, opener: true)
            balloons << fence.join("\n\n")
            fence = nil
          end
        else
          balloons << piece
        end
      end
      balloons << fence.join("\n\n") if fence
      balloons
    end

    # Does this paragraph close an open fence? Any line starting with the fence
    # marker counts. `opener: true` skips the FIRST line — the line that opened
    # the block, which cannot be its own closer.
    def closes_fence?(piece, opener: false)
      lines = piece.lines
      lines[(opener ? 1 : 0)..].any? { |line| line.start_with?(FENCE) }
    end

    # The soft cap: a paragraph longer than SENTENCE_AFTER splits after sentence
    # closers followed by whitespace — which is why `3.9s` and `www.` survive
    # (their period is not followed by whitespace) and a decimal does too. A
    # leftover without a closer stays one balloon.
    #
    # Sentences are then RE-GROUPED into ~SENTENCE_AFTER blocks (
    # the split is a cap, not a mandate). Without the regroup, a 680-char
    # paragraph of short sentences would atomize into one balloon per sentence —
    # a paragraph that was ONE bubble becomes 40 WhatsApp messages for no
    # latency win.
    def split_long(balloon)
      return [balloon] if balloon.length <= SENTENCE_AFTER

      parts = balloon.split(SENTENCE_BOUNDARY).map(&:strip).reject(&:empty?)
      return [balloon] if parts.empty?

      parts.each_with_object([+""]) do |sentence, balloons|
        if balloons.last.empty?
          balloons.last << sentence
        elsif balloons.last.length + sentence.length + 1 <= SENTENCE_AFTER
          balloons.last << " #{sentence}"
        else
          balloons << +sentence
        end
      end
    end

    PARAGRAPH_BREAK = /\n\s*\n+/
    FENCE = "```"
    SENTENCE_BOUNDARY = /(?<=[.!?…])\s+(?=\S)/
    private_constant :PARAGRAPH_BREAK, :FENCE, :SENTENCE_BOUNDARY
  end
end