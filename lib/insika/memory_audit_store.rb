# frozen_string_literal: true

require "digest/sha2"
require "json"
require "time"

module Insika
  # RFC-0031 C2: append-only, per-cell audit of MEMORY mutations. Every
  # operator mutation of a cell appends a line (who, when, what, old->new
  # digests). The entry holds DIGESTS of values, never the values — the forget
  # line records that a deletion happened without the deleted content (the
  # digest is not invertible, and keys are fact names — provenance, not
  # payload). Capped per cell (no retention hook, no delete path: the audit
  # outlives what it describes). `record` rescues EVERYTHING — a failed audit
  # write never fails the mutation it describes.
  #
  # The capped-list RMW caveat (context_trace_store.rb's discipline): one cell
  # key, written on the command's fiber; a cross-process race loses the loser's
  # append — a trace-level loss, not a correctness one.
  class MemoryAuditStore
    SCOPE = "memory_audit" # store key = the memory cell scope
    MAX_PER_CELL = 200 # oldest dropped; the cap bounds growth

    Entry = Data.define(:at, :action, :actor, :key, :tenant, :customer,
                        :old_hash, :new_hash, :note)

    def initialize(store:, clock: nil)
      @store = store
      @clock = clock # -> Time, injectable for specs
    end

    # action: "put" | "forget" | "purge". key = the fact name (provenance,
    # not payload). Appends + caps. Rescues EVERYTHING -> Entry | nil (the
    # audit never breaks a command).
    def record(cell:, action:, actor:, key: nil, tenant: nil, customer: nil,
               old_hash: nil, new_hash: nil, note: nil)
      entry = {
        "at" => timestamp,
        "action" => action.to_s,
        "actor" => actor.to_s,
        "key" => Coercion.presence(key),
        "tenant" => Coercion.presence(tenant),
        "customer" => Coercion.presence(customer),
        "old_hash" => Coercion.presence(old_hash),
        "new_hash" => Coercion.presence(new_hash),
        "note" => Coercion.presence(note)
      }
      list = (@store.get(SCOPE, cell.to_s) || []) + [entry]
      @store.set(SCOPE, cell.to_s, list.last(MAX_PER_CELL))
      to_entry(entry)
    rescue StandardError
      nil
    end

    # -> [Entry] most recent first. [] if none. A broken backend degrades to
    # [] — the audit is read to RENDER, never to gate.
    def for_cell(cell, limit: 100)
      Array(@store.get(SCOPE, cell.to_s)).reverse.first(limit).map { |e| to_entry(e) }
    rescue StandardError
      []
    end

    # The digest the callers share: SHA-256 hexdigest of JSON.generate(value)
    # (or value.to_s for non-JSON scalars). -> String
    def self.digest(value)
      payload = case value
                when Hash, Array then JSON.generate(value)
                else value.to_s
                end
      Digest::SHA256.hexdigest(payload)
    end

    private

    def to_entry(record)
      Entry.new(at: record["at"], action: record["action"], actor: record["actor"],
                key: record["key"], tenant: record["tenant"], customer: record["customer"],
                old_hash: record["old_hash"], new_hash: record["new_hash"], note: record["note"])
    end

    def timestamp = (clock ? clock.call : Time.now.utc).utc.iso8601(6)

    def clock = @clock
  end
end