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
    KEY_PREFIX = "session:"

    Session = Data.define(:id, :messages, :vars, :memory_refs,
                          :created_at, :updated_at, :briefing, :evidence) do
      # Trailing members with defaults: an old record without the "briefing" /
      # "evidence" keys reads as empty/nil without a migration.
      def initialize(id:, messages:, vars:, memory_refs:, created_at:, updated_at:,
                     briefing: nil, evidence: nil)
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
      @store.set(SCOPE, key, record)
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
    def append_messages(id, messages)
      record = fetch!(id)
      incoming = (messages.is_a?(Hash) ? [messages] : Array(messages))
                 .map { |msg| stamp(deep_stringify(msg)) }
      record["messages"] += incoming
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> Session (SHALLOW merge: an existing nested key is replaced wholesale,
    # not merged). NotFoundError if absent.
    def update_vars(id, vars)
      record = fetch!(id)
      record["vars"] = record["vars"].merge(deep_stringify(vars))
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # RFC-0029 C4: appends this turn's evidence (ids + ungrounded delta) to the
    # session record. RMW like append_messages — the SessionActor serializes
    # same-session turns; the copy is in the method comment.
    def append_evidence(id, ids:, ungrounded:)
      record = fetch!(id)
      ev = record["evidence"] ||= { "ids" => [], "ungrounded" => 0 }
      fresh = (ev["ids"] + Array(ids).map(&:to_s).reject(&:empty?)).uniq.last(EvidenceLedger::MAX_IDS)
      ev["ids"] = fresh
      ev["ungrounded"] = ev["ungrounded"].to_i + ungrounded.to_i
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> Session. Upsert ONE briefing field. The pack owns the schema; the
    # engine validates nothing about field NAMES here (the tools do, at the
    # write edge). value is a String (anything else -> to_s); a BLANK value
    # (after strip) REMOVES the key — absence means "not yet asked" (RFC-0028
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
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> Session. Upsert the agreed next step; a blank text clears to nil
    # (RFC-0028 D4). NotFoundError if absent.
    def set_next_step(id, text:)
      record = fetch!(id)
      briefing = record["briefing"] ||= { "fields" => {}, "next_step" => nil }
      briefing["next_step"] = Coercion.presence(Coercion.utf8(text.to_s))
      record["updated_at"] = timestamp
      @store.set(SCOPE, key_for(id), record)
      to_session(record)
    end

    # -> bool (delegates to the backend: false for a nonexistent id)
    def delete(id)
      @store.delete(SCOPE, key_for(id))
    end

    # -> enumerates ids without the "session:" prefix. Without a block,
    # returns an Enumerator.
    def each_id
      return enum_for(:each_id) unless block_given?

      @store.list(SCOPE, KEY_PREFIX).each do |key|
        yield key.delete_prefix(KEY_PREFIX)
      end
    end

    private

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
        evidence: record["evidence"]
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
