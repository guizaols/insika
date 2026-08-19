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
  # the record gains `origin`/`created_at`/`expires_at`, the
  # (tenant, customer) pair becomes first-class at the API (`customer:`
  # builds the same "memory:<tenant>:<customer>" scope the Executor derives),
  # and the store enumerates its cells (the Studio drill, the doctor, the
  # retention sweep). Migration is lazy: tolerant reads, materialized on the
  # first write. The audit trail lives in `MemoryAuditStore` (C2), NOT here —
  # this stays a dumb domain store.
  #
  # NOT to be confused with `Insika::Stores::Memory` (in-memory KV backend):
  # this is the domain store; that one is one of the backends this writes to.
  class MemoryStore
    SCOPE_PREFIX = "memory"       # scope = "memory:<tenant>"
    FACT_PREFIX  = "fact:"
    NOTE_PREFIX  = "note:"
    DEFAULT_TENANT = "_default"   # no tenant in the Command

    # the record's provenance. A closed string set: "legacy"
    # (migrated, unknown writer), "engine" (the remember tool / an
    # integration write), "operator" (Studio edit), "distilled"
    # reserved).
    ORIGIN_LEGACY = "legacy"

    # the per-SESSION cell marker. Engine-owner memory with no
    # customer and no explicit tenant falls back to the session (executor
    # parity) — the cell is MARKED "memory:chat:<session id>" so the drill and
    # the doctor never read a conversation as a customer (a bare
    # "memory:<session id>" cell is indistinguishable from a single-tenant
    # customer ref). A real tenant NAMED "chat" would collide with the marker
    # (its customer cells would read as session cells) — accepted, merchant
    # ids live in a different namespace in practice.
    SESSION_TAG = "chat"

    Fact = Data.define(:key, :value, :origin, :created_at, :updated_at, :expires_at)
    Note = Data.define(:id, :text, :created_at)

    def initialize(store:, clock: nil)
      @store = store
      @clock = clock # -> Time, injectable for specs
    end

    # Upsert (last-write-wins, Store contract). `customer:` PRESENT moves the
    # scope to the [tenant:]customer cell (WS8's rule — nil tenant + customer
    # -> bare "memory:<customer>", NEVER _default). `origin` defaults to
    # "engine" (the remember tool's write). `expires_at` (ISO8601 String) is
    # normalized and validated here — an invalid value raises ValidationError
    # (a silently dropped LGPD expiry date is the defect). Preserves the
    # existing record's created_at; rewrites a legacy record in the full
    # shape. -> Fact
    def put_fact(tenant:, key:, value:, customer: nil, origin: "engine", expires_at: nil)
      scope = scope_for(tenant, customer)
      current = @store.get(scope, FACT_PREFIX + key.to_s)
      prev = current.is_a?(Hash) ? current : {}
      stamp = timestamp
      record = {
        "key" => key.to_s, "value" => stringify(value),
        "origin" => Coercion.presence(origin) || "engine",
        "created_at" => Coercion.presence(prev["created_at"]) || Coercion.presence(prev["updated_at"]) || stamp,
        "updated_at" => stamp,
        "expires_at" => normalize_expiry(expires_at)
      }
      @store.set(scope, FACT_PREFIX + key.to_s, record)
      to_fact(record)
    end

    # -> Fact | nil (tolerant read: missing origin -> "legacy", created_at ->
    # updated_at, expires_at -> nil).
    def get_fact(tenant:, key:, customer: nil)
      record = @store.get(scope_for(tenant, customer), FACT_PREFIX + key.to_s)
      record && to_fact(record)
    end

    # -> [Fact] sorted by key. Facts whose expires_at <= now are EXCLUDED
    # (D5: an expired fact is never injected nor shown, even before the
    # sweep runs).
    def facts(tenant:, customer: nil)
      scope = scope_for(tenant, customer)
      @store.list(scope, FACT_PREFIX).filter_map do |k|
        record = @store.get(scope, k)
        next unless record

        fact = to_fact(record)
        next if expired?(fact)

        fact
      end
    end

    # -> bool (did it exist?)
    def forget_fact(tenant:, key:, customer: nil)
      @store.delete(scope_for(tenant, customer), FACT_PREFIX + key.to_s)
    end

    # CAS write (WS8): only writes when the STORED fact's updated_at still
    # equals the caller's revision — a fact a concurrent writer already moved
    # is refused instead of clobbered (last-write-wins is the default; this is
    # the opt-in optimistic path). -> Fact (written) | nil (lost the race — the
    # caller must re-read and retry). The read-compare-write rides
    # `@store.transaction` (the repo rule) — `next`, never `return`, inside.
    def replace_if_revision(tenant:, key:, value:, expected_revision:,
                            customer: nil, origin: "engine", expires_at: nil)
      @store.transaction do
        current = @store.get(scope_for(tenant, customer), FACT_PREFIX + key.to_s)
        next nil if current.nil? || current["updated_at"] != expected_revision

        put_fact(tenant: tenant, key: key, value: value, customer: customer,
                 origin: origin, expires_at: expires_at)
      end
    end

    # Purges the WHOLE scope (WS8 — forget_customer / delete_tenant_data). The
    # scope string is the isolation boundary: one cell per
    # (tenant-or-customer), so zeroing the cell cannot touch another's.
    # The list-then-delete rides `@store.transaction` (the repo rule): an erasure
    # that is half-applied is the LGPD defect, and a fact written between the
    # list and the deletes would survive a purge that reported success.
    # -> count of records purged.
    def purge(tenant:, customer: nil)
      scope = scope_for(tenant, customer)
      @store.transaction do
        keys = @store.list(scope)
        keys.each { |k| @store.delete(scope, k) }
        keys.size
      end
    end

    # Purges a TENANT and every customer cell under it (WS8 phase 2 —
    # delete_tenant_data). The tenant's own cell ("memory:<tenant>") plus each
    # cell whose scope starts with "memory:<tenant>:" (the customer cells),
    # plus the tenant's SESSION-marked cells ("memory:chat:<tenant>:*" — in
    # multi-tenant a session id is "<tenant>:<id>", so its memory cell is
    # "memory:chat:<tenant>:<id>"). The scope enumeration is the Store's — no
    # session-derived list, so a customer cell whose session was already
    # deleted is still purged. ONE transaction for the whole tenant (the repo
    # rule): the scope enumeration and every delete see the same snapshot, so a
    # customer cell born mid-purge cannot slip through a deletion that reported
    # success. -> count of records purged.
    def purge_tenant(tenant)
      cell = scope_for(tenant)
      @store.transaction do
        scopes = [cell] + @store.scopes("#{cell}:") +
                 @store.scopes("#{SCOPE_PREFIX}:#{SESSION_TAG}:#{tenant}:")
        scopes.sum do |scope|
          keys = @store.list(scope)
          keys.each { |k| @store.delete(scope, k) }
          keys.size
        end
      end
    end

    # Age-based prune (WS8 retention). New : `scope:` limits the pass
    # to ONE cell; a fact with an explicit expires_at is SKIPPED (D5 — the
    # explicit override owns that fact's life). -> count removed.
    def prune_older_than(time, scope: nil)
      cutoff = time.utc.iso8601
      removed = 0
      scopes = scope ? [scope] : @store.scopes("#{SCOPE_PREFIX}:")
      scopes.each do |sc|
        @store.list(sc).each do |k|
          rec = @store.get(sc, k)
          next if rec && rec["expires_at"] # the override owns this fact's life

          stamp = rec && (rec["updated_at"] || rec["created_at"])
          next unless stamp && stamp.to_s < cutoff

          @store.delete(sc, k)
          removed += 1
        end
      end
      removed
    end

    # Removes facts whose expires_at <= now (default clock), EVERY cell.
    # -> count removed.
    def prune_expired(now = nil)
      cutoff = (now || self.now).utc
      removed = 0
      @store.scopes("#{SCOPE_PREFIX}:").each do |scope|
        @store.list(scope).each do |k|
          rec = @store.get(scope, k)
          next unless rec && rec["expires_at"]

          begin
            next unless Time.iso8601(rec["expires_at"]) <= cutoff
          rescue ArgumentError
            next
          end

          @store.delete(scope, k)
          removed += 1
        end
      end
      removed
    end

    # --- enumeration (the drill / doctor / retention inputs) -----------

    # -> [{scope:, tenant: String|nil, customer: String|nil}] — every "memory:*"
    # scope, classified by SHAPE (D6). _default -> {tenant: nil, customer: nil}.
    def cells
      @store.scopes("#{SCOPE_PREFIX}:").map { |scope| self.class.parse_cell(scope) }
    end

    # -> [{scope:, tenant:, customer:}] — the cells that hold CUSTOMER memory:
    # 2+-segment scopes always (except the SESSION-marked cells — a session is
    # never a customer); 1-segment scopes whose name is not _default and not in
    # `reserved` (the caller's agent ids / tenant cells). Sorted by scope.
    def customer_cells(reserved: [])
      excluded = Array(reserved).map(&:to_s)
      cells.reject do |c|
        self.class.session_cell?(c) ||
          (c[:tenant].nil? && (c[:customer].nil? || excluded.include?(c[:customer])))
      end.sort_by { |c| c[:scope] }
    end

    # Is this a classified cell the engine's per-SESSION cell
    # ("memory:chat:<session id>")? The one classification both the drill and
    # the doctor share — a session-derived cell must never read as a customer.
    def self.session_cell?(cell) = cell[:tenant] == SESSION_TAG

    # The public cell string for a pair (the commands and the Studio build URLs
    # and audit keys with this — the same string the Executor derives).
    def cell_for(tenant, customer = nil) = scope_for(tenant, customer)

    # The shared classification (public — the Studio/commands split audit
    # fields): "memory:acme:c-123" -> {scope:, tenant: "acme", customer: "c-123"};
    # "memory:c-123" -> {scope:, tenant: nil, customer: "c-123"};
    # "memory:_default" -> {scope:, tenant: nil, customer: nil}.
    def self.parse_cell(scope)
      rest = scope.to_s.sub(/\A#{SCOPE_PREFIX}:/, "")
      base, tail = rest.split(":", 2)
      if base == DEFAULT_TENANT && tail.nil?
        { scope: scope, tenant: nil, customer: nil }
      elsif tail
        { scope: scope, tenant: base, customer: tail }
      else
        { scope: scope, tenant: nil, customer: base }
      end
    end

    # Append. `at` (ISO8601) goes at the START of the key so `list` returns the notes in
    # chronological order; `id`/`at` injectable for deterministic tests. -> Note
    def add_note(tenant:, text:, id: SecureRandom.uuid, at: nil, customer: nil)
      at ||= timestamp
      record = { "id" => id.to_s, "text" => text.to_s, "created_at" => at }
      @store.set(scope_for(tenant, customer), NOTE_PREFIX + "#{at}:#{id}", record)
      to_note(record)
    end

    # Cheap fact count for the drill index (keys only, no payload reads). -> Integer
    def fact_count(tenant:, customer: nil)
      @store.list(scope_for(tenant, customer), FACT_PREFIX).size
    end

    # -> [Note] MOST RECENT first, capped by `limit`.
    def notes(tenant:, limit: nil, customer: nil)
      scope = scope_for(tenant, customer)
      keys = @store.list(scope, NOTE_PREFIX).reverse # list is chronological -> reverse = most recent first
      keys = keys.first(limit) if limit
      keys.filter_map do |k|
        record = @store.get(scope, k)
        record && to_note(record)
      end
    end

    private

    # WS8's rule (executor.rb:1679 parity): customer present -> the
    # [tenant:]customer cell; nil tenant + customer -> the bare customer cell,
    # NEVER memory:_default:<customer>.
    def scope_for(tenant, customer = nil)
      base = Coercion.blank?(tenant) ? DEFAULT_TENANT : tenant
      cust = Coercion.presence(customer)
      return "#{SCOPE_PREFIX}:#{cust}" if cust && Coercion.blank?(tenant)

      cust ? "#{SCOPE_PREFIX}:#{base}:#{cust}" : "#{SCOPE_PREFIX}:#{base}"
    end

    def to_fact(record)
      Fact.new(key: record["key"], value: record["value"],
               origin: Coercion.presence(record["origin"]) || ORIGIN_LEGACY,
               created_at: Coercion.presence(record["created_at"]) || Coercion.presence(record["updated_at"]),
               updated_at: record["updated_at"], expires_at: record["expires_at"])
    end

    def to_note(record) = Note.new(id: record["id"], text: record["text"], created_at: record["created_at"])

    def expired?(fact)
      return false if fact.expires_at.nil?

      Time.iso8601(fact.expires_at) <= now
    rescue ArgumentError
      false
    end

    def now = (@clock ? @clock.call : Time.now.utc).utc

    # Microsecond precision ON PURPOSE: updated_at is the CAS revision
    # (replace_if_revision) — second-precision collides for two writes in the
    # same second (WS8).
    def timestamp = now.iso8601(6)

    # nil | canonical ISO8601(6); invalid -> ValidationError (fail-fast on an
    # LGPD field — a silently dropped expiry date is the defect).
    def normalize_expiry(expires_at)
      return nil if expires_at.nil? || expires_at.to_s.strip.empty?

      Time.iso8601(expires_at.to_s).utc.iso8601(6)
    rescue ArgumentError
      raise Insika::ValidationError,
            "expires_at must be an ISO8601 timestamp (got #{expires_at.inspect})"
    end

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