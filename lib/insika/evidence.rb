# frozen_string_literal: true

require "json"

module Insika
  # RFC-0029 — the evidence contract (engine half).
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
    # `kind` is the PILOT PACK's value, never a gem constant (RFC-0036: the
    # engine owns nothing about product shape).
    Spec = Data.define(:kind, :items_path, :attachments_path) do
      PATH_RE = /\A[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)*\z/

      # String | Hash | nil -> Spec | nil. Raises ValidationError on a blank kind
      # or an empty/ill-formed path. All at ingestion, never at the turn.
      def self.parse(raw)
        return nil if raw.nil? || raw == false

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
    def self.valid_attachments(list)
      Array(list).filter_map do |entry|
        next unless entry.is_a?(Hash)

        url = (entry["url"] || entry[:url]).to_s
        next if url.empty?

        caption = Coercion.presence(entry["caption"] || entry[:caption])
        { "type" => (entry["type"] || entry[:type]).to_s,
          "url" => url[0, URL_MAX],
          "caption" => caption }
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
              "line" => Coercion.utf8((item["line"] || item[:line]).to_s)[0, LINE_MAX] }
          end
          lean = { "items" => lean_items }
          attachments = Insika::Evidence.valid_attachments(SchemaGuard.dig(raw, spec.attachments_path))
          [lean, attachments]
        end
      end
    end
  end

  # The session evidence ledger (C4). A session-scoped SET with an `ungrounded`
  # counter: records every product id that entered the context via an
  # evidence-declared tool this session (RFC-0029 §4.2), plus the ungrounded
  # counter that feeds the daily metric. It is NOT a policy object — it records
  # and answers `ids` / `ungrounded` / `lines`; it never decides.
  class EvidenceLedger
    # Oldest-evicted cap: a session that outlives it needs a real cap or the row
    # grows forever.
    MAX_IDS = 1_000

    def initialize(store: nil, session_id: nil)
      @store = store
      @session_id = session_id
      @ids = []
      @ungrounded = 0
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

      @store.append_evidence(@session_id, ids: @ids, ungrounded: @ungrounded)
      @ids = []
      @ungrounded = 0
      self
    rescue Insika::Error
      self
    end

    private

    def session_ids
      return [] unless @store && @session_id

      session = @store.find(@session_id)
      Array(session&.evidence&.fetch("ids", [])).map(&:to_s)
    rescue Insika::NotFoundError
      []
    end
  end
end
