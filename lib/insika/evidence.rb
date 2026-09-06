# frozen_string_literal: true

require "json"

module Insika
  #   — the evidence contract (engine half).
  #
  # A tool DECLARES `evidence` in its manifest; the engine then does BOTH jobs
  # from the same declaration: strips the result down to `{items: [{id, line}]}`
  # for the model (the lean envelope), and appends every `id` to the session
  # evidence ledger. No second flag, no "lean but not evidence" mode — a
  # half-configuration cannot exist, which is what keeps "no claim without a
  # tool ID" a tautology at the envelope instead of a convention.
  #
  # Everything here is pure Ruby, no IO: the ToolEnvelope calls it after the real
  # tool returns. It does NOT write anything — the ledger write is the envelope's,
  # via the state.
  module Evidence
    # The declaration (D1/C2.1). Parses three authorable shapes:
    #
    #   { "evidence": "products" }                             // bare kind
    #   { "evidence": { "kind": "products" } }                 // full form
    #   { "evidence": { "kind": "products",
    #                   "items": "results",
    #                   "attachments": "cards" } }             // non-default paths
    #
    # `kind` is the PILOT PACK's value, never a gem constant (the
    # engine owns nothing about product shape).
    Spec = Data.define(:kind, :items_path, :attachments_path) do
      PATH_RE = /\A[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)*\z/

      # String | Hash | Spec | nil -> Spec | nil. Raises ValidationError on a blank kind
      # or an empty/ill-formed path. All at ingestion, never at the turn.
      def self.parse(raw)
        return nil if raw.nil? || raw == false
        # A data tool hands the envelope its definition's evidence — already a Spec.
        return raw if raw.is_a?(Spec)

        h = raw.is_a?(String) ? { "kind" => raw } : Coercion.deep_stringify(raw)
        h = h.is_a?(Hash) ? h : {}
        kind = Coercion.presence(h["kind"])
        raise Insika::ValidationError, "evidence.kind is required" if kind.nil?

        items = presence_path(h["items"], "items")
        attachments = presence_path(h["attachments"], "attachments")
        new(kind: kind, items_path: items, attachments_path: attachments)
      end

      def to_h
        { "kind" => kind, "items" => items_path, "attachments" => attachments_path }.compact
      end

      def self.presence_path(value, default)
        s = Coercion.presence(value)
        s = default if s.nil?
        raise Insika::ValidationError, "evidence.#{default}: not a dotted path" unless PATH_RE.match?(s)

        s
      end
      private_class_method :presence_path
    end

    # The lean result the model sees — the ONLY thing that survives the envelope.
    MAX_ITEMS = 16
    # Line truncation keeps the transcript lean by force (E1).
    LINE_MAX = 200
    # Attachments are a channel nicety, never the answer; bounded on purpose.
    MAX_ATTACHMENTS = 16
    URL_MAX = 500

    # The attachments contract, validated for the outbox (channel side, never the
    # model): [{ "type" => "card"|"image", "url" => String, "caption" => String|nil }].
    # Entries without a String url, or beyond MAX_ATTACHMENTS, are DROPPED — never
    # a turn failure (the card is a channel nicety, not the answer).
    #
    # Three OPTIONAL keys survive when present: `id` (the product the card stands
    # for — what a presentation tool joins on), and `component`/`title` (stamped
    # by a presentation call so the channel knows what it is rendering). Absent =
    # absent; a card with none of them is byte-identical to before.
    OPTIONAL_KEYS = %w[id component title].freeze

    def self.valid_attachments(list)
      Array(list).filter_map do |entry|
        next unless entry.is_a?(Hash)

        url = (entry["url"] || entry[:url]).to_s
        next if url.empty?

        caption = Coercion.presence(entry["caption"] || entry[:caption])
        caption &&= Coercion.utf8(caption)
        card = { "type" => (entry["type"] || entry[:type]).to_s,
                 "url" => url[0, URL_MAX],
                 "caption" => caption }
        OPTIONAL_KEYS.each do |k|
          v = Coercion.presence(entry[k] || entry[k.to_sym])
          card[k] = v.to_s if v
        end
        card
      end.first(MAX_ATTACHMENTS)
    end

    # Result shaping, stateless — callable from any tool-call fiber (the parallel
    # tool_concurrency path). No shared state in this class.
    class Processor
      class << self
        # -> the parsed Hash the evidence paths dig into. For `evidence_envelope`
        # the raw body lives under `__insika_body` (D3); a code tool returns the
        # object itself. Raises JSON::ParserError on a non-JSON envelope body —
        # the envelope turns that into `{error:}`, nothing recorded (fail closed:
        # no IDs, no claims to make).
        def raw(spec, result)
          return result unless result.is_a?(Hash) && result.key?("__insika_body")

          JSON.parse(result["__insika_body"].to_s)
        end

        # -> [lean, attachments]. Assumes the shape already passed
        # SchemaGuard.violation_output. Items are capped and lines truncated; the
        # model must never see a null where the contract says items.
        def build(spec, raw)
          items = SchemaGuard.dig(raw, spec.items_path) || []
          lean_items = items.first(MAX_ITEMS).map do |item|
            { "id" => (item["id"] || item[:id]).to_s,
              # the line is what the model reads: truncated here; sanitized by the
              # envelope's fence when the agent has `fencing` on (bytes as-is when off).
              "line" => Coercion.utf8((item["line"] || item[:line]).to_s)[0, LINE_MAX] }
          end
          lean = { "items" => lean_items }
          cards = stamp_ids(items, SchemaGuard.dig(raw, spec.attachments_path))
          [lean, Insika::Evidence.valid_attachments(cards)]
        end

        # Items and attachments come from the SAME payload, one card per item in
        # order — so a card that names no id of its own takes the id of the item at
        # its position. That id is what a presentation tool later joins on. Stamped
        # on the RAW list, before malformed cards are dropped: pairing after the
        # drop would shift every later card onto the wrong product.
        def stamp_ids(items, cards)
          Array(cards).each_with_index.map do |card, i|
            next card unless card.is_a?(Hash) && (card["id"] || card[:id]).nil?

            item = items[i]
            id = item.is_a?(Hash) ? (item["id"] || item[:id]).to_s : ""
            id.empty? ? card : card.merge("id" => id)
          end
        end
      end
    end
  end

  # The session evidence ledger (C4). A session-scoped SET with an `ungrounded`
  # counter: records every product id that entered the context via an
  # evidence-declared tool this session , plus the ungrounded
  # counter that feeds the daily metric. It is NOT a policy object — it records
  # and answers `ids` / `ungrounded` / `lines`; it never decides.
  class EvidenceLedger
    # Oldest-evicted cap: a session that outlives it needs a real cap or the row
    # grows forever.
    MAX_IDS = 1_000
    # Cards kept per session, one per id, newest wins — enough for the last few
    # searches, so "show me the second one" a turn later still has a card to show.
    MAX_CARDS = 64

    def initialize(store: nil, session_id: nil)
      @store = store
      @session_id = session_id
      @ids = []
      @cards = []
      @ungrounded = 0
    end

    # -> one card per id (newest wins), capped. Shared by the ledger and the
    # session store so both keep the same set.
    def self.merge_cards(*lists)
      lists.flatten.compact
           .each_with_object({}) { |c, h| h[c["id"]] = c if c.is_a?(Hash) && c["id"] }
           .values.last(MAX_CARDS)
    end

    # The in-memory accumulator (the envelope appends, the validator/enforcer
    # read the union). The PERSISTED list is appended on flush (Executor, stage 8)
    # — the envelope never blocks on the store.
    def record(ids)
      @ids.concat(Array(ids).map(&:to_s).reject(&:empty?))
      self
    end

    # -> the effective set for THIS turn: persisted session evidence (loaded at
    # build) + the turn's new ids, deduped, capped.
    def ids
      (session_ids + @ids).uniq.last(MAX_IDS)
    end

    # The cards an evidence tool returned alongside its items, hoarded for the
    # presentation tool. Only cards with an id are kept (nothing to join on
    # otherwise). Persisted with the ids on flush.
    def record_cards(cards)
      @cards.concat(Array(cards).select { |c| c.is_a?(Hash) && c["id"] })
      self
    end

    # -> the session's cards (persisted) + this turn's, one per id, newest wins.
    def cards
      self.class.merge_cards(session_evidence["cards"], @cards)
    end

    attr_reader :ungrounded

    def ungrounded_count(claim)
      @ungrounded += 1
      claim
    end

    # -> self, flushed to the session record. Idempotent. A store OR not-found
    # failure is swallowed (evidence is audit — it must never fail a committed
    # turn; a session purged mid-turn by forget_customer/session_purge reads as
    # "nothing to append", never an explosion).
    def flush!
      return self unless @store && @session_id

      @store.append_evidence(@session_id, ids: @ids, ungrounded: @ungrounded, cards: @cards)
      @ids = []
      @cards = []
      @ungrounded = 0
      @session_evidence = nil
      self
    rescue Insika::Error
      self
    end

    private

    def session_ids
      Array(session_evidence["ids"]).map(&:to_s)
    end

    # Read ONCE per ledger (= per turn): a batch of gated calls must not re-read
    # the session row for each. `flush!` forgets it, so the next read sees what
    # it just appended.
    def session_evidence
      return {} unless @store && @session_id

      @session_evidence ||= begin
        @store.find(@session_id)&.evidence || {}
      rescue Insika::NotFoundError
        {}
      end
    end
  end
end
