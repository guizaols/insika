# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  # AGENT-MEMORY DOMAIN store. Two layers
  # scoped per tenant over any `Insika::Store`: `profile` (stable key-value
  # facts) and `notes` (append-only free-form notes). Mirrors the
  # `PendingActionStore` (normalizes symbol→string on write, O(n) scan on
  # read, records with a timestamp).
  #
  # NOT to be confused with `Insika::Stores::Memory` (in-memory KV backend):
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

    # CAS write (WS8): only writes when the STORED fact's updated_at still
    # equals the caller's revision — a fact a concurrent writer already moved
    # is refused instead of clobbered (last-write-wins is the default; this is
    # the opt-in optimistic path). -> Fact (written) | nil (lost the race — the
    # caller must re-read and retry). The read-compare-write rides
    # `@store.transaction` (the repo rule) — `next`, never `return`, inside.
    def replace_if_revision(tenant:, key:, value:, expected_revision:)
      @store.transaction do
        current = @store.get(scope_for(tenant), FACT_PREFIX + key.to_s)
        next nil if current.nil? || current["updated_at"] != expected_revision

        put_fact(tenant: tenant, key: key, value: value)
      end
    end

    # Purges the WHOLE scope (WS8 — forget_customer / delete_tenant_data). The
    # scope string is the isolation boundary: one cell per
    # (tenant-or-customer), so zeroing the cell cannot touch another's.
    # -> count of records purged.
    def purge(tenant:)
      scope = scope_for(tenant)
      keys = @store.list(scope)
      keys.each { |k| @store.delete(scope, k) }
      keys.size
    end

    # Purges a TENANT and every customer cell under it (WS8 phase 2 —
    # delete_tenant_data). The tenant's own cell ("memory:<tenant>") plus each
    # cell whose scope starts with "memory:<tenant>:" (the customer cells).
    # The scope enumeration is the Store's — no session-derived list, so a
    # customer cell whose session was already deleted is still purged.
    # -> count of records purged.
    def purge_tenant(tenant)
      cell = scope_for(tenant)
      scopes = [cell] + @store.scopes("#{cell}:")
      scopes.sum do |scope|
        keys = @store.list(scope)
        keys.each { |k| @store.delete(scope, k) }
        keys.size
      end
    end

    # Age-based prune across EVERY cell (WS8 retention): a fact older than the
    # cutoff by its updated_at, a note by its created_at. The scope enumeration
    # is the Store's — nothing session-derived. -> count of records removed.
    def prune_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.scopes("#{SCOPE_PREFIX}:").each do |scope|
        @store.list(scope).each do |k|
          rec = @store.get(scope, k)
          stamp = rec && (rec["updated_at"] || rec["created_at"])
          next unless stamp && stamp.to_s < cutoff

          @store.delete(scope, k)
          removed += 1
        end
      end
      removed
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

    # Microsecond precision ON PURPOSE: updated_at is the CAS revision
    # (replace_if_revision) — second-precision collides for two writes in the
    # same second (WS8).
    def timestamp = Time.now.utc.iso8601(6)

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
