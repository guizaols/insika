# frozen_string_literal: true

require "time"

module Insika
  # the durable CONTACT STATE cell per (tenant, customer)— ONE
  # derived cell, never a transition log (D2): `granted | revoked |
  # unavailable`, the sends-without-reply counter and the last outbound
  # timestamp. Dumb domain store: it holds no policy and no follow-up records
  # (the firer and the inbound hook own those transformations).
  #
  # Invariants (the firer enforces them, the store only records):
  #   · only `granted` may be messaged; absent = never messaged (:consent block);
  #   · `revoked` is immediate and permanent until the customer speaks;
  #   · `unavailable` means silence ≠ refusal — set when sends_without_reply
  #     reaches the policy's ceiling; further fires block until the customer
  #     speaks; any customer message reopens (sets granted + zeroes the counter).
  #
  # The customer identifier is the SAME string the message contract carries
  # (`customer:` on /v1/messages, WS8).
  class ContactStore
    SCOPE = "contacts"
    STATES = %w[granted revoked unavailable].freeze

    Cell = Data.define(:state, :sends_without_reply, :last_outbound_at, :updated_at)

    def initialize(store:)
      @store = store
    end

    # -> [Cell] | nil (absent = never messaged — the :consent block). nil
    # customer -> nil (an untagged conversation has no cell).
    def get(tenant:, customer:)
      return nil if customer.to_s.empty?

      record = @store.get(SCOPE, key(tenant, customer))
      record && to_cell(record)
    end

    # -> { "<tenant>:<customer>" => raw record } — the whole scope, for the
    # doctor's contact summary and the Studio (read-only folds; the mutations
    # go through the commands, D10).
    def cells
      @store.list(SCOPE).each_with_object({}) do |k, acc|
        record = @store.get(SCOPE, k)
        acc[k] = record if record
      end
    end

    # The ONLY writers. Each is a read-check-write on the cell (#transaction —
    # two processes flipping the state in the same second serialize).

    # Any customer message reopens the conversation: `granted` + the counter
    # reset. The consent record itself (D2/D7) is the `schedule` tool call.
    def set_granted(tenant:, customer:, now: Time.now.utc)
      write(tenant, customer, now) do |record|
        record["state"] = "granted"
        record["sends_without_reply"] = 0
      end
    end

    # D7: the schedule tool's consent write. The customer agreeing
    # in-conversation IS the consent — but ONLY a customer message reopens
    # (D2): this NEVER lifts `:unavailable` and NEVER resets
    # sends_without_reply, so a re-booking inside the scheduled turn cannot
    # clear the silence protection. Creates the cell when absent (the first
    # consent). Raises Insika::ValidationError on `:revoked` — an opt-out is
    # permanent; the caller refuses.
    def consent(tenant:, customer:, now: Time.now.utc)
      raise Insika::ValidationError, "customer is required" if customer.to_s.empty?

      @store.transaction do
        record = @store.get(SCOPE, key(tenant, customer)) ||
                 { "state" => "granted", "sends_without_reply" => 0,
                   "last_outbound_at" => nil, "updated_at" => nil }
        if record["state"] == "revoked"
          raise Insika::ValidationError,
                "this customer opted out — you cannot schedule a follow-up"
        end

        record["state"] ||= "granted"
        record["updated_at"] = now.iso8601
        @store.set(SCOPE, key(tenant, customer), record)
        to_cell(record)
      end
    end

    # Keyword / channel opt-out / operator: immediate and permanent until the
    # customer speaks. Nothing auto-revokes.
    def set_revoked(tenant:, customer:, now: Time.now.utc)
      write(tenant, customer, now) do |record|
        record["state"] = "revoked"
      end
    end

    # Silence reached the policy's ceiling (the firer counts sends without a
    # reply); further fires block until the customer speaks.
    def mark_unavailable(tenant:, customer:, now: Time.now.utc)
      write(tenant, customer, now) do |record|
        record["state"] = "unavailable"
      end
    end

    # The firer's call: sends_without_reply += 1, last_outbound_at = now.
    # Creates the cell when absent (granted — the firer checks the GO before
    # bumping, so a bump only happens after the consent gate).
    def bump_outbound(tenant:, customer:, now: Time.now.utc)
      write(tenant, customer, now) do |record|
        record["state"] ||= "granted"
        record["sends_without_reply"] = record["sends_without_reply"].to_i + 1
        record["last_outbound_at"] = now.iso8601
      end
    end

    # Purge paths (C11 — the LGPD footprint): one cell; a whole tenant's
    # (prefix scan); age-based. All nil-safe.

    # -> true | false (did the cell exist?)
    def delete(tenant:, customer:)
      return false if customer.to_s.empty?

      @store.delete(SCOPE, key(tenant, customer))
    end

    # -> count removed.
    def purge(tenant:)
      prefix = "#{tenant_id(tenant)}:"
      keys = @store.list(SCOPE).select { |k| k.start_with?(prefix) }
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    # Cells untouched past the cutoff (WS8 retention). -> count removed.
    def delete_older_than(time)
      cutoff = time.utc.iso8601
      removed = 0
      @store.list(SCOPE).each do |k|
        record = @store.get(SCOPE, k)
        next unless record && record["updated_at"].to_s < cutoff

        @store.delete(SCOPE, k)
        removed += 1
      end
      removed
    end

    private

    # One cell per (tenant, customer); blank tenant -> the literal "platform"
    # (outcome_store.rb's rule — contact, follow-up and outcome keys share one
    # tenant segment so the purge prefix scans line up).
    def key(tenant, customer)
      "#{tenant_id(tenant)}:#{customer}"
    end

    def tenant_id(tenant)
      t = tenant.to_s
      t.empty? ? "platform" : t
    end

    # Read-check-write inside the backend transaction (the budget_ledger.rb:38
    # discipline): two writers racing the same cell serialize on the backend
    # lock and the loser re-reads.
    def write(tenant, customer, now, &block)
      raise Insika::ValidationError, "customer is required" if customer.to_s.empty?

      @store.transaction do
        record = @store.get(SCOPE, key(tenant, customer)) ||
                 { "state" => "granted", "sends_without_reply" => 0,
                   "last_outbound_at" => nil, "updated_at" => nil }
        block.call(record)
        record["updated_at"] = now.iso8601
        @store.set(SCOPE, key(tenant, customer), record)
        to_cell(record)
      end
    end

    def to_cell(record)
      Cell.new(state: record["state"], sends_without_reply: record["sends_without_reply"].to_i,
               last_outbound_at: record["last_outbound_at"], updated_at: record["updated_at"])
    end
  end
end
