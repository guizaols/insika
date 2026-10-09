# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # Domain store for sessions. Persists transcript + vars
  # over an injected Insika::Store, with a fixed schema
  # `session:<id>` in the "sessions" scope.
  #
  # The persisted transcript is the SOURCE OF TRUTH for reconstruction; live
  # events are just delivery state. The message shape
  # (`{"role"=>, "content"=>}`, role ∈ user|assistant|system|tool) is the
  # same one `Runner#seed_history` already consumes — the Executor converts nothing.
  #
  # Normalizes symbol→string on WRITE (the backend only guarantees round-trip of
  # JSON types); READ returns the data as it comes from the backend
  # (string keys), never symmetrizing back to symbols.
  class SessionStore
    include Coercion

    SCOPE = "sessions"
    STATS_SCOPE = "session_stats" # one small record per session, see #write
    # Optional Strings a caller sends to label a conversation in the Studio
    # (shown and searched there; no effect on memory scope).
    CUSTOMER_LABELS = %w[customer_name customer_phone].freeze
    KEY_PREFIX = "session:"

    Session = Data.define(:id, :messages, :vars, :memory_refs,
                          :created_at, :updated_at, :briefing, :evidence, :compaction) do
      # Trailing members with defaults: an old record without the "briefing" /
      # "evidence" / "compaction" keys reads as empty/nil without a migration.
      def initialize(id:, messages:, vars:, memory_refs:, created_at:, updated_at:,
                     briefing: nil, evidence: nil, compaction: nil)
        super
      end
    end

    # store: any Insika::Store (Memory, SQLite, ...) — injected by the
    # composition root (config/wiring.rb). SessionStore does not know the
    # concrete backend.
    def initialize(store:)
      @store = store
    end

    # -> Session; ArgumentError if id already exists (a duplicate session is a
    # domain violation — it never overwrites silently).
    def create(id: SecureRandom.uuid, vars: {})
      key = key_for(id)
      raise ArgumentError, "session already exists: #{id}" unless @store.get(SCOPE, key).nil?

      now = timestamp
      record = {
        "id" => id.to_s,
        "messages" => [],
        "vars" => deep_stringify(vars),
        "memory_refs" => [],
        "briefing" => { "fields" => {}, "next_step" => nil },
        "evidence" => { "ids" => [], "ungrounded" => 0 },
        "created_at" => now,
        "updated_at" => now
      }
      write(record)
      to_session(record)
    end

    # -> Session | nil
    def find(id)
      record = @store.get(SCOPE, key_for(id))
      record && to_session(record)
    end

    # -> Session (transcript += messages). Read-modify-write on the task's own
    # fiber, without a lock. Each message gets an "at" (ISO8601 UTC) if not
    # provided. NotFoundError if the session does not exist.
    #
    # CONCURRENCY LIMITATION (R2c): the RMW (read record -> += -> set) is
    # atomic ONLY because the SessionActor serializes turns of the same session
    # (one owner at a time). That serialization exists solely in SUPERVISED mode
    # (the actor loop lives on the supervisor). Two concurrent send_message on the
    # same session_id OUTSIDE that path (e.g. calling append_messages directly, or
    # a non-supervised deployment) would interleave read/set and LOSE messages —
    # there is no compare-and-swap here. Route same-session writes through the
    # SessionActor; see session_actor.rb.
    # `agent:` names the session's agent when it has none yet (a turn with no
    # customer never stamped one), riding this write instead of one of its own.
    def append_messages(id, messages, agent: nil)
      record = fetch!(id)
      incoming = (messages.is_a?(Hash) ? [messages] : Array(messages))
                 .map { |msg| stamp(deep_stringify(msg)) }
      record["messages"] += incoming
      if agent && Coercion.presence((record["vars"] ||= {})["agent"]).nil?
        record["vars"]["agent"] = agent.to_s
      end
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # -> Session (SHALLOW merge: an existing nested key is replaced wholesale,
    # not merged). NotFoundError if absent.
    def update_vars(id, vars)
      record = fetch!(id)
      record["vars"] = record["vars"].merge(deep_stringify(vars))
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # appends this turn's evidence (ids + ungrounded delta) to the
    # session record. RMW like append_messages — the SessionActor serializes
    # same-session turns; the copy is in the method comment.
    def append_evidence(id, ids:, ungrounded:, cards: [])
      record = fetch!(id)
      ev = record["evidence"] ||= { "ids" => [], "ungrounded" => 0 }
      fresh = (ev["ids"] + Array(ids).map(&:to_s).reject(&:empty?)).uniq.last(EvidenceLedger::MAX_IDS)
      ev["ids"] = fresh
      ev["ungrounded"] = ev["ungrounded"].to_i + ungrounded.to_i
      # the cards those ids came with (one per id, newest wins) — what a
      # presentation tool joins on in a LATER turn. Absent until a card arrives.
      ev["cards"] = EvidenceLedger.merge_cards(ev["cards"], cards) unless Array(cards).empty?
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # -> Session. Upsert ONE briefing field. The pack owns the schema; the
    # engine validates nothing about field NAMES here (the tools do, at the
    # write edge). value is a String (anything else -> to_s); a BLANK value
    # (after strip) REMOVES the key — absence means "not yet asked" (
    # D4). NotFoundError if the session does not exist.
    #
    # CONCURRENCY NOTE: an unlocked RMW (read -> mutate -> set), like
    # append_messages — but the SessionActor argument does NOT apply here. A
    # briefing writer is a system tool, never enveloped, and with
    # tool_concurrency > 1 the gem runs each call in its OWN fiber — outside the
    # actor's per-session turn serialization. The RMW is still safe, for a
    # different reason: nothing in the read/mutate/set path suspends. Store
    # get/set are synchronous (the SQLite write semaphore is a non-yielding fast
    # path when free), and a fiber only switches at a scheduler suspension point
    # — so no other writer can interleave mid-RMW (measured: N concurrent
    # writers lose nothing). It holds ONLY while that path never suspends; an
    # async store (a real yield in get/set) would need a lock or CAS.
    def update_briefing(id, field:, value:)
      record = fetch!(id)
      briefing = record["briefing"] ||= { "fields" => {}, "next_step" => nil }
      value = Coercion.presence(Coercion.utf8(value.to_s))
      value ? briefing["fields"][field.to_s] = value : briefing["fields"].delete(field.to_s)
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # -> Session. Upsert the agreed next step; a blank text clears to nil
    # NotFoundError if absent.
    def set_next_step(id, text:)
      record = fetch!(id)
      briefing = record["briefing"] ||= { "fields" => {}, "next_step" => nil }
      briefing["next_step"] = Coercion.presence(Coercion.utf8(text.to_s))
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # -> Session. Persists the in-session compaction state (RFC-0044): the
    # summary of messages[0...upto] plus the boundary. `upto` is MONOTONIC —
    # a write that does not move the boundary forward is a no-op (a stale
    # double-write from a racing worker can never move it backwards). `runs`
    # counts compactions over the session's lifetime (the trace reports it).
    #
    # CONCURRENCY NOTE: an unlocked RMW (read -> mutate -> set), like
    # update_briefing — and safe for the same reason: nothing in the
    # read/mutate/set path suspends, so no other writer can interleave
    # mid-RMW. The LLM call that produced the summary happened BEFORE this
    # method; only the plain write lives here.
    def set_compaction(id, summary: nil, upto:, model: nil, native: nil)
      record = fetch!(id)
      current = record["compaction"]
      upto = Integer(upto)
      return to_session(record) if current && upto <= current["upto"].to_i

      record["compaction"] = {
        "summary" => native ? nil : Coercion.utf8(summary.to_s),
        "native" => native && Coercion.deep_stringify(native),
        "upto" => upto,
        "runs" => (current ? current["runs"].to_i : 0) + 1,
        "model" => Coercion.presence(model.to_s),
        "at" => timestamp
      }.compact
      record["updated_at"] = timestamp
      write(record)
      to_session(record)
    end

    # -> bool (delegates to the backend: false for a nonexistent id)
    def delete(id)
      @store.delete(STATS_SCOPE, key_for(id))
      @store.delete(SCOPE, key_for(id))
    end

    # -> enumerates ids without the "session:" prefix. Without a block,
    # returns an Enumerator.
    # -> [Session] every record, from ONE bulk read of the backend (see
    # Store#entries) instead of a read per id.
    def all
      @store.entries(SCOPE, KEY_PREFIX).map { |_, record| to_session(record) }
    end

    # -> [Session] the `limit` most recently written sessions, newest first, from
    # one read (Store#recent) instead of reading every session to sort them.
    # `offset` skips that many of the newest (the next page).
    def recent(limit, offset: 0)
      # offset only when paging: a backend written for the 3-argument #recent keeps working
      rows = offset.zero? ? @store.recent(SCOPE, KEY_PREFIX, limit) : @store.recent(SCOPE, KEY_PREFIX, limit, offset)
      rows.map { |_, record| to_session(record) }
    end

    # -> Integer sessions stored, from the keys alone (no record is read).
    def count = @store.list(SCOPE, KEY_PREFIX).size

    # What a dashboard needs of a session without its messages: a few bytes per
    # session, written with it, instead of the whole record (messages included).
    # last_role: who spoke last ("user" = the customer is waiting); nil on stats
    # written before it existed, until the session's next write.
    Stat = Data.define(:id, :updated_at, :message_count, :vars, :last_role) do
      def initialize(id:, updated_at:, message_count:, vars:, last_role: nil) = super
    end

    # -> [Stat] every session's stats, in no particular order: small enough to read
    # whole, so a reader never depends on the order they were written in.
    def all_stats
      @store.entries(STATS_SCOPE, KEY_PREFIX).map { |key, stat| to_stat(key, stat) }
    end

    # Writes the stats of every session that has none (sessions stored before
    # stats existed) and deletes stats whose session is gone. Idempotent and safe
    # with the app running: each batch re-reads inside a transaction, skipping a
    # session that wrote its own stats meanwhile or was deleted. -> stats written.
    def backfill_stats(batch: 500)
      have = @store.list(STATS_SCOPE, KEY_PREFIX).to_set
      written = 0
      @store.list(SCOPE, KEY_PREFIX).reject { |key| have.include?(key) }.each_slice(batch) do |keys|
        @store.transaction do
          keys.each do |key|
            next if @store.get(STATS_SCOPE, key)

            record = @store.get(SCOPE, key) or next
            @store.set(STATS_SCOPE, key, stats_of(record))
            written += 1
          end
        end
      end
      live = @store.list(SCOPE, KEY_PREFIX).to_set
      @store.list(STATS_SCOPE, KEY_PREFIX).each { |key| @store.delete(STATS_SCOPE, key) unless live.include?(key) }
      written
    end

    def each_id
      return enum_for(:each_id) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        yield key.delete_prefix(KEY_PREFIX)
      end
    end

    private

    # The one write of a session record: the record and its stats, side by side.
    def write(record)
      key = key_for(record["id"])
      @store.set(SCOPE, key, record)
      @store.set(STATS_SCOPE, key, stats_of(record))
    end

    def stats_of(record)
      last = Array(record["messages"]).last
      vars = record["vars"] || {}
      { "updated_at" => record["updated_at"], "message_count" => Array(record["messages"]).size,
        "agent" => vars["agent"], "customer" => vars["customer"],
        "last_role" => last.is_a?(Hash) ? last["role"] : nil, **vars.slice(*CUSTOMER_LABELS) }.compact
    end

    def to_stat(key, stat)
      Stat.new(id: key.delete_prefix(KEY_PREFIX), updated_at: stat["updated_at"],
               message_count: stat["message_count"].to_i,
               vars: stat.slice("agent", "customer", *CUSTOMER_LABELS),
               last_role: stat["last_role"])
    end

    def key_for(id)
      "#{KEY_PREFIX}#{id}"
    end

    # Loads the raw record; NotFoundError if absent (nonexistent session ->
    # HTTP 404). Backend errors (StoreError) propagate without re-wrapping.
    def fetch!(id)
      record = @store.get(SCOPE, key_for(id))
      raise Insika::NotFoundError, "session not found: #{id}" if record.nil?

      record
    end

    def to_session(record)
      Session.new(
        id: record["id"],
        messages: record["messages"],
        vars: record["vars"],
        memory_refs: record["memory_refs"],
        created_at: record["created_at"],
        updated_at: record["updated_at"],
        briefing: record["briefing"] || { "fields" => {}, "next_step" => nil },
        evidence: record["evidence"],
        compaction: record["compaction"]
      )
    end

    # Stamps "at" (ISO8601 UTC) on the message when absent; preserves whatever is provided.
    def stamp(message)
      message["at"] ||= timestamp
      message
    end

    def timestamp
      Time.now.utc.iso8601
    end
  end
end
