# frozen_string_literal: true

require "securerandom"
require "time"

module Harness
  # AGENT-MEMORY DOMAIN store. Two layers
  # scoped per tenant over any `Harness::Store`: `profile` (stable key-value
  # facts) and `notes` (append-only free-form notes). Mirrors the
  # `PendingActionStore` (normalizes symbol→string on write, O(n) scan on
  # read, records with a timestamp).
  #
  # NOT to be confused with `Harness::Stores::Memory` (in-memory KV backend):
  # this is the domain store; that one is one of the backends this writes to.
  class MemoryStore
    SCOPE_PREFIX = "memory"       # scope = "memory:<tenant>"
    FACT_PREFIX  = "fact:"
    NOTE_PREFIX  = "note:"
    DEFAULT_TENANT = "_default"   # no tenant in the Command

    Fact = Data.define(:key, :value, :updated_at)
    Note = Data.define(:id, :text, :created_at)

    def initialize(store:)
      @store = store
    end

    # Upsert (last-write-wins, Store contract). -> Fact
    def put_fact(tenant:, key:, value:)
      record = { "key" => key.to_s, "value" => stringify(value), "updated_at" => timestamp }
      @store.set(scope_for(tenant), FACT_PREFIX + key.to_s, record)
      to_fact(record)
    end

    # -> Fact | nil
    def get_fact(tenant:, key:)
      record = @store.get(scope_for(tenant), FACT_PREFIX + key.to_s)
      record && to_fact(record)
    end

    # -> [Fact] sorted by key (list is lexicographic).
    def facts(tenant:)
      scope = scope_for(tenant)
      @store.list(scope, FACT_PREFIX).filter_map do |k|
        record = @store.get(scope, k)
        record && to_fact(record)
      end
    end

    # -> bool (did it exist?)
    def forget_fact(tenant:, key:)
      @store.delete(scope_for(tenant), FACT_PREFIX + key.to_s)
    end

    # Append. `at` (ISO8601) goes at the START of the key so `list` returns the notes in
    # chronological order; `id`/`at` injectable for deterministic tests. -> Note
    def add_note(tenant:, text:, id: SecureRandom.uuid, at: nil)
      at ||= timestamp
      record = { "id" => id.to_s, "text" => text.to_s, "created_at" => at }
      @store.set(scope_for(tenant), NOTE_PREFIX + "#{at}:#{id}", record)
      to_note(record)
    end

    # -> [Note] MOST RECENT first, capped by `limit`.
    def notes(tenant:, limit: nil)
      scope = scope_for(tenant)
      keys = @store.list(scope, NOTE_PREFIX).reverse # list is chronological -> reverse = most recent first
      keys = keys.first(limit) if limit
      keys.filter_map do |k|
        record = @store.get(scope, k)
        record && to_note(record)
      end
    end

    private

    def scope_for(tenant) = "#{SCOPE_PREFIX}:#{tenant.nil? || tenant.to_s.empty? ? DEFAULT_TENANT : tenant}"

    def to_fact(record) = Fact.new(key: record["key"], value: record["value"], updated_at: record["updated_at"])
    def to_note(record) = Note.new(id: record["id"], text: record["text"], created_at: record["created_at"])

    def timestamp = Time.now.utc.iso8601

    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
  end
end
