# frozen_string_literal: true

require_relative "detectors"

module Insika
  module Safety
    # Deterministic output redaction on the STREAM. The turn
    # streams `content` deltas, so we cannot "unsay" text already sent — the filter
    # sits between the provider chunks and the `:content` event and only ever emits
    # text it has PROVEN clean.
    #
    # The hard part ("fronteira de chunk"): a CPF/secret can arrive split
    # across two chunks and neither half matches on its own. A naive delta-by-delta
    # regex leaks "by construction". So the filter keeps a SLIDING BUFFER: it retains
    # the tail that might still be growing into a match (Detectors::OPEN_TAIL, which
    # also covers the unbounded `sk-…` case a fixed window can't) and emits only the
    # prefix that no future chunk can reach back into — at the cost of a few chars of
    # tail latency. On flush (turn end) the remainder is redacted and released.
    #
    # Stateful and single-turn: one instance per streamed turn.
    class OutputFilter
      attr_reader :redaction_counts

      # `corpus` : the compiled corpus for the turn — the
      # language-filtered PII set and its open-tail pattern. Default = the
      # full shipped corpus (parity).
      def initialize(corpus: Corpus.compile)
        @corpus = corpus
        @buf = +""
        @emitted = +"" # full redacted text emitted so far (for the persisted content)
        @redaction_counts = Hash.new(0)
      end

      # Feeds one raw provider delta. Returns the redacted, proven-clean slice to
      # emit downstream (may be empty when everything is still held back).
      def push(delta)
        @buf << delta.to_s
        release(safe_cut)
      end

      # Turn end: redact and release whatever is still buffered (nothing can grow
      # anymore). Returns the final redacted tail (may be empty).
      def flush = release(@buf.length)

      # The FULL redacted text produced across the turn (deltas + flush) — what gets
      # persisted / put in the terminal event, so storage and stream agree.
      def output = @emitted.dup

      private

      # Index up to which the buffer can be emitted without risking a split match.
      # Start optimistic (emit all), then pull back to protect (a) an incomplete
      # match still growing at the tail and (b) any complete match that would be
      # straddled by the cut.
      def safe_cut
        cut = @buf.length

        if (m = @buf.match(@corpus.open_tail))
          cut = [cut, m.begin(0)].min
        end

        @corpus.match_ranges(@buf).each do |b, e|
          cut = b if b < cut && cut < e
        end

        [cut, 0].max
      end

      # Redacts and releases @buf[0...cut], advancing the buffer. Accumulates the
      # redacted text and the per-category counts.
      def release(cut)
        return +"" if cut <= 0

        chunk = @buf[0...cut]
        @buf = @buf[cut..] || +""
        redacted, counts = @corpus.redact(chunk)
        counts.each { |name, n| @redaction_counts[name] += n }
        @emitted << redacted
        redacted
      end
    end
  end
end
