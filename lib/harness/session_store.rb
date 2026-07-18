# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # Domain store for sessions. Persists transcript + vars
  # over an injected Harness::Store, with a fixed schema
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
                          :created_at, :updated_at)

    # store: any Harness::Store (Memory, SQLite, ...) — injected by the
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
    # fiber, without a lock (one node, one owner per task). Each message
    # gets an "at" (ISO8601 UTC) if not provided. NotFoundError if the session does not exist.
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
      raise Harness::NotFoundError, "session not found: #{id}" if record.nil?

      record
    end

    def to_session(record)
      Session.new(
        id: record["id"],
        messages: record["messages"],
        vars: record["vars"],
        memory_refs: record["memory_refs"],
        created_at: record["created_at"],
        updated_at: record["updated_at"]
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
