# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::MemoryStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }

  describe "facts (profile layer)" do
    it "put_fact + get_fact round-trip" do
      fact = store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(fact.key).to eq("plano")
      expect(fact.value).to eq("premium")
      expect(fact.updated_at).to be_a(String)
      expect(store.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
    end

    it "upsert: last-write-wins" do
      store.put_fact(tenant: "acme", key: "plano", value: "basic")
      store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(store.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
      expect(store.facts(tenant: "acme").size).to eq(1)
    end

    it "get_fact nonexistent -> nil" do
      expect(store.get_fact(tenant: "acme", key: "nope")).to be_nil
    end

    it "facts ordered by key" do
      store.put_fact(tenant: "acme", key: "zeta", value: "z")
      store.put_fact(tenant: "acme", key: "alpha", value: "a")
      expect(store.facts(tenant: "acme").map(&:key)).to eq(%w[alpha zeta])
    end

    it "forget_fact removes and returns whether it existed" do
      store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(store.forget_fact(tenant: "acme", key: "plano")).to be(true)
      expect(store.get_fact(tenant: "acme", key: "plano")).to be_nil
    end

    it "normalizes symbol->string in the value" do
      fact = store.put_fact(tenant: "acme", key: "k", value: :sym)
      expect(fact.value).to eq("sym")
    end
  end

  describe "record shape " do
    it "new fields round-trip; created_at stamped on create and preserved across an upsert" do
      fact = store.put_fact(tenant: "acme", key: "size", value: "M")
      expect(fact.origin).to eq("engine")
      expect(fact.expires_at).to be_nil
      expect(fact.created_at).to be_a(String)
      expect(fact.created_at).to eq(fact.updated_at)

      later = store.put_fact(tenant: "acme", key: "size", value: "L")
      expect(later.created_at).to eq(fact.created_at)
      expect(later.updated_at).not_to eq(fact.updated_at)
      expect(later.origin).to eq("engine")
    end

    it "a legacy record reads tolerantly: origin legacy, created_at from updated_at, expires nil; one upsert materializes the shape" do
      backend.set("memory:acme", "fact:size", { "key" => "size", "value" => "M",
                                                 "updated_at" => "2026-01-01T00:00:00.000000Z" })
      legacy = store.get_fact(tenant: "acme", key: "size")
      expect(legacy.origin).to eq("legacy")
      expect(legacy.created_at).to eq("2026-01-01T00:00:00.000000Z")
      expect(legacy.expires_at).to be_nil

      rewritten = store.put_fact(tenant: "acme", key: "size", value: "L")
      expect(rewritten.origin).to eq("engine")
      expect(rewritten.created_at).to eq("2026-01-01T00:00:00.000000Z") # preserved
    end

    it "explicit origin and expires_at round-trip (canonical ISO8601); invalid expires_at raises ValidationError" do
      fact = store.put_fact(tenant: "acme", key: "k", value: "v", origin: "operator",
                            expires_at: "2026-12-31T00:00:00Z")
      expect(fact.origin).to eq("operator")
      expect(Time.iso8601(fact.expires_at)).to eq(Time.iso8601("2026-12-31T00:00:00Z"))

      expect { store.put_fact(tenant: "acme", key: "k", value: "v", expires_at: "not-a-date") }
        .to raise_error(Insika::ValidationError, /expires_at/)
    end

    it "a blank origin defaults to engine, blank expires_at to nil" do
      fact = store.put_fact(tenant: "acme", key: "k", value: "v", origin: "", expires_at: "  ")
      expect(fact.origin).to eq("engine")
      expect(fact.expires_at).to be_nil
    end
  end

  describe "customer scoping " do
    it "customer: -> the [tenant:]customer cell" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      expect(backend.get("memory:acme:c-1", "fact:size")).not_to be_nil
      expect(store.get_fact(tenant: "acme", customer: "c-1", key: "size").value).to eq("M")
    end

    it "tenant nil + customer -> the bare customer cell, NEVER memory:_default:<c>" do
      store.put_fact(tenant: nil, customer: "c-1", key: "size", value: "M")
      expect(backend.get("memory:c-1", "fact:size")).not_to be_nil
      expect(backend.get("memory:_default:c-1", "fact:size")).to be_nil
    end

    it "E3 unit half: the same customer under two tenants is two disjoint cells" do
      store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
      store.put_fact(tenant: "globex", customer: "c-1", key: "size", value: "L")
      expect(store.facts(tenant: "acme", customer: "c-1").map(&:value)).to eq(["M"])
      expect(store.facts(tenant: "globex", customer: "c-1").map(&:value)).to eq(["L"])
      expect(backend.get("memory:acme:c-1", "fact:size")["value"]).to eq("M")
      expect(backend.get("memory:globex:c-1", "fact:size")["value"]).to eq("L")
    end

    it "customer: applies to notes and purge" do
      store.add_note(tenant: "acme", customer: "c-1", text: "prefere email")
      store.add_note(tenant: "acme", text: "sem cliente")
      expect(store.notes(tenant: "acme", customer: "c-1").map(&:text)).to eq(["prefere email"])

      expect(store.purge(tenant: "acme", customer: "c-1")).to eq(1)
      expect(store.notes(tenant: "acme", customer: "c-1")).to be_empty
      expect(store.notes(tenant: "acme").map(&:text)).to eq(["sem cliente"])
    end

    it "customer: on the CAS path and forget_fact" do
      first = store.put_fact(tenant: "acme", customer: "c-1", key: "k", value: "v1")
      written = store.replace_if_revision(tenant: "acme", customer: "c-1", key: "k", value: "v2",
                                          expected_revision: first.updated_at)
      expect(written.value).to eq("v2")
      expect(store.forget_fact(tenant: "acme", customer: "c-1", key: "k")).to be(true)
      expect(store.get_fact(tenant: "acme", customer: "c-1", key: "k")).to be_nil
    end
  end

  describe "expiry " do
    let(:clock) { -> { Time.utc(2026, 8, 17, 12, 0, 0) } }
    subject(:clocked) { described_class.new(store: backend, clock: clock) }

    it "facts EXCLUDES expires_at <= now (injected clock), before any sweep" do
      clocked.put_fact(tenant: "acme", key: "expired", value: "x", expires_at: "2026-08-17T11:59:00Z")
      clocked.put_fact(tenant: "acme", key: "live", value: "y", expires_at: "2026-08-18T00:00:00Z")
      clocked.put_fact(tenant: "acme", key: "noexpiry", value: "z")
      expect(clocked.facts(tenant: "acme").map(&:key)).to eq(%w[live noexpiry])
    end

    it "prune_expired removes only past-expiry facts, across every cell" do
      clocked.put_fact(tenant: "acme", key: "a", value: "1", expires_at: "2026-08-17T11:00:00Z")
      clocked.put_fact(tenant: "acme", key: "b", value: "2", expires_at: "2026-08-18T00:00:00Z")
      clocked.put_fact(tenant: "acme", key: "c", value: "3")
      clocked.put_fact(tenant: "globex", key: "d", value: "4", expires_at: "2026-08-16T00:00:00Z")

      expect(clocked.prune_expired).to eq(2)
      expect(clocked.facts(tenant: "acme").map(&:key)).to eq(%w[b c])
      expect(clocked.facts(tenant: "globex")).to be_empty
    end

    it "prune_older_than(scope:) touches ONE cell; a fact with an explicit expires_at survives the cutoff" do
      store.put_fact(tenant: "acme:123", key: "old", value: "1")
      store.put_fact(tenant: "acme:123", key: "pinned", value: "2", expires_at: "2099-01-01T00:00:00Z")
      store.put_fact(tenant: "acme:456", key: "old", value: "1")
      backend.set("memory:acme:123", "fact:old",
                  backend.get("memory:acme:123", "fact:old").merge("updated_at" => "2020-01-01T00:00:00.000000Z"))
      backend.set("memory:acme:123", "fact:pinned",
                  backend.get("memory:acme:123", "fact:pinned").merge("updated_at" => "2020-01-01T00:00:00.000000Z"))
      backend.set("memory:acme:456", "fact:old",
                  backend.get("memory:acme:456", "fact:old").merge("updated_at" => "2020-01-01T00:00:00.000000Z"))

      expect(store.prune_older_than(Time.utc(2026, 1, 1), scope: "memory:acme:123")).to eq(1)
      expect(store.get_fact(tenant: "acme:123", key: "old")).to be_nil
      expect(store.get_fact(tenant: "acme:123", key: "pinned")).not_to be_nil
      expect(store.get_fact(tenant: "acme:456", key: "old")).not_to be_nil
    end

    it "prune_older_than without scope still touches every cell (WS8 parity)" do
      store.put_fact(tenant: "acme:123", key: "old", value: "1")
      store.put_fact(tenant: "acme:456", key: "old", value: "1")
      backend.set("memory:acme:123", "fact:old",
                  backend.get("memory:acme:123", "fact:old").merge("updated_at" => "2020-01-01T00:00:00.000000Z"))
      backend.set("memory:acme:456", "fact:old",
                  backend.get("memory:acme:456", "fact:old").merge("updated_at" => "2020-01-01T00:00:00.000000Z"))

      expect(store.prune_older_than(Time.utc(2026, 1, 1))).to eq(2)
    end
  end

  describe "cell enumeration " do
    it "parse_cell classifies by SHAPE" do
      expect(described_class.parse_cell("memory:acme:c-123"))
        .to eq({ scope: "memory:acme:c-123", tenant: "acme", customer: "c-123" })
      expect(described_class.parse_cell("memory:c-123"))
        .to eq({ scope: "memory:c-123", tenant: nil, customer: "c-123" })
      expect(described_class.parse_cell("memory:_default"))
        .to eq({ scope: "memory:_default", tenant: nil, customer: nil })
      expect(described_class.parse_cell("memory:acme"))
        .to eq({ scope: "memory:acme", tenant: nil, customer: "acme" })
    end

    it "cells enumerates every memory scope classified by shape" do
      store.put_fact(tenant: "acme", key: "k", value: "v")
      store.put_fact(tenant: "acme", customer: "c-1", key: "k", value: "v")
      store.put_fact(tenant: "globex", customer: "c-1", key: "k", value: "v")
      store.put_fact(tenant: nil, key: "k", value: "v")

      expect(store.cells.map { |c| c[:scope] })
        .to eq(["memory:_default", "memory:acme", "memory:acme:c-1", "memory:globex:c-1"])
    end

    it "customer_cells: 2+ segments always, bare cells filtered by reserved, _default excluded" do
      store.put_fact(tenant: "acme", key: "k", value: "v")
      store.put_fact(tenant: "acme", customer: "c-1", key: "k", value: "v")
      store.put_fact(tenant: nil, key: "k", value: "v")
      store.put_fact(tenant: nil, customer: "agent-1", key: "k", value: "v")

      # the caller reserves its own cells (agent ids + _default); the tenant's
      # own shared cell is genuinely ambiguous and the caller names it too
      expect(store.customer_cells(reserved: %w[agent-1 acme _default]))
        .to eq([{ scope: "memory:acme:c-1", tenant: "acme", customer: "c-1" }])
      # without the reserved list the bare cells read as customers
      expect(store.customer_cells.map { |c| c[:customer] }).to include("agent-1", "acme")
    end

    it "customer_cells NEVER lists the engine's per-SESSION cells (memory:chat:<id>)" do
      # the executor's session fallback : "chat:<session id>"
      store.put_fact(tenant: "chat:s-1", key: "k", value: "v")
      store.put_fact(tenant: "acme", customer: "c-1", key: "k", value: "v")

      expect(store.customer_cells.map { |c| c[:scope] }).to eq(["memory:acme:c-1"])
      # a multi-tenant session id ("acme:chat-1") marks the same way
      store.put_fact(tenant: "chat:acme:chat-1", key: "k", value: "v")
      expect(store.customer_cells.map { |c| c[:scope] }).to eq(["memory:acme:c-1"])
    end

    it "session_cell? is the shared classification" do
      expect(described_class.session_cell?({ tenant: "chat", customer: "s-1" })).to be(true)
      expect(described_class.session_cell?({ tenant: "acme", customer: "c-1" })).to be(false)
      expect(described_class.session_cell?({ tenant: nil, customer: "c-1" })).to be(false)
    end

    it "cell_for is the public scope string the commands/audit share" do
      expect(store.cell_for("acme", "c-1")).to eq("memory:acme:c-1")
      expect(store.cell_for(nil, "c-1")).to eq("memory:c-1")
      expect(store.cell_for("acme")).to eq("memory:acme")
      expect(store.cell_for(nil)).to eq("memory:_default")
    end
  end

  describe "notes (notes layer)" do
    it "add_note + notes most-recent-first" do
      store.add_note(tenant: "acme", text: "primeira", at: "2026-01-01T00:00:00Z")
      store.add_note(tenant: "acme", text: "segunda", at: "2026-01-02T00:00:00Z")
      expect(store.notes(tenant: "acme").map(&:text)).to eq(%w[segunda primeira])
    end

    it "limit caps (the N most recent)" do
      3.times { |i| store.add_note(tenant: "acme", text: "n#{i}", at: "2026-01-0#{i + 1}T00:00:00Z") }
      expect(store.notes(tenant: "acme", limit: 2).map(&:text)).to eq(%w[n2 n1])
    end

    it "note carries id and created_at" do
      note = store.add_note(tenant: "acme", text: "oi", id: "fixed", at: "2026-01-01T00:00:00Z")
      expect(note.id).to eq("fixed")
      expect(note.created_at).to eq("2026-01-01T00:00:00Z")
    end
  end

  describe "tenant isolation" do
    it "tenant A does not see B's memory" do
      store.put_fact(tenant: "a", key: "k", value: "va")
      store.add_note(tenant: "a", text: "na")
      expect(store.facts(tenant: "b")).to eq([])
      expect(store.notes(tenant: "b")).to eq([])
      expect(store.get_fact(tenant: "b", key: "k")).to be_nil
    end

    it "tenant nil/empty -> _default scope (does not break)" do
      store.put_fact(tenant: nil, key: "k", value: "v")
      expect(store.get_fact(tenant: nil, key: "k").value).to eq("v")
      # _default is a tenant distinct from any other
      expect(store.get_fact(tenant: "acme", key: "k")).to be_nil
    end
  end

  describe "replace_if_revision (WS8 CAS)" do
    it "writes only when the stored revision matches; else nil (lost the race)" do
      first = store.put_fact(tenant: "acme", key: "k", value: "v1")
      second = store.put_fact(tenant: "acme", key: "k", value: "v2") # LWW moved the revision

      # a stale writer is refused, not clobbered
      expect(store.replace_if_revision(tenant: "acme", key: "k", value: "stale",
                                       expected_revision: first.updated_at)).to be_nil
      expect(store.get_fact(tenant: "acme", key: "k").value).to eq("v2")

      # a writer holding the CURRENT revision wins
      written = store.replace_if_revision(tenant: "acme", key: "k", value: "v3",
                                          expected_revision: second.updated_at)
      expect(written.value).to eq("v3")
      expect(store.get_fact(tenant: "acme", key: "k").value).to eq("v3")
    end

    it "a fact that does not exist is refused (the CAS is not an upsert)" do
      expect(store.replace_if_revision(tenant: "acme", key: "ghost", value: "x",
                                       expected_revision: "anything")).to be_nil
    end

    it "works on SQLite without leaking the transaction (the WS2 trap)" do
      sqlite = Insika::Stores::SQLite.new(path: ":memory:")
      durable = described_class.new(store: sqlite)
      fact = durable.put_fact(tenant: "acme", key: "k", value: "v1")
      expect(durable.replace_if_revision(tenant: "acme", key: "k", value: "v2",
                                         expected_revision: "stale")).to be_nil
      expect(durable.put_fact(tenant: "acme", key: "k", value: "v2")).to be_a(described_class::Fact)
    ensure
      sqlite&.close
    end
  end

  describe "purge (WS8 — forget_customer)" do
    it "zeroes the WHOLE scope and reports the count; neighbours are untouched" do
      store.put_fact(tenant: "acme:123", key: "pedido", value: "open")
      store.add_note(tenant: "acme:123", text: "prefere email")
      store.put_fact(tenant: "acme:456", key: "pedido", value: "delivered")

      expect(store.purge(tenant: "acme:123")).to eq(2)
      expect(store.facts(tenant: "acme:123")).to be_empty
      expect(store.notes(tenant: "acme:123")).to be_empty
      # the OTHER customer's cell is untouched
      expect(store.get_fact(tenant: "acme:456", key: "pedido").value).to eq("delivered")
    end

    it "purge on an empty scope is 0, never an error" do
      expect(store.purge(tenant: "acme:999")).to eq(0)
    end

    # The repo rule: a read-modify-write goes through Store#transaction. A
    # list-then-delete outside one can report an erasure that a concurrent write
    # survived — the LGPD defect.
    it "the list-then-delete of purge/purge_tenant rides ONE transaction" do
      spy = TransactionSpyStore.new(Insika::Stores::Memory.new)
      counted = described_class.new(store: spy)
      counted.put_fact(tenant: "acme:123", key: "pedido", value: "open")
      counted.put_fact(tenant: "acme", key: "catalogo", value: "v2")
      spy.reset!

      expect(counted.purge(tenant: "acme:123")).to eq(1)
      expect(spy.transactions).to eq(1)
      expect(spy.deletes_outside_transaction).to eq(0)

      spy.reset!
      expect(counted.purge_tenant("acme")).to eq(1)
      expect(spy.transactions).to eq(1)
      expect(spy.deletes_outside_transaction).to eq(0)
    end

    it "purge/purge_tenant work on SQLite without leaking the transaction" do
      sqlite = Insika::Stores::SQLite.new(path: ":memory:")
      durable = described_class.new(store: sqlite)
      durable.put_fact(tenant: "acme", key: "catalogo", value: "v2")
      durable.put_fact(tenant: "acme:123", key: "pedido", value: "open")

      expect(durable.purge(tenant: "acme:123")).to eq(1)
      expect(durable.purge_tenant("acme")).to eq(1)
      # a leaked BEGIN IMMEDIATE would deadlock/raise on the next write
      expect(durable.put_fact(tenant: "acme", key: "catalogo", value: "v3").value).to eq("v3")
    ensure
      sqlite&.close
    end

    it "purge_tenant also purges the tenant's SESSION-marked cells " do
      store.put_fact(tenant: "acme", key: "catalogo", value: "v2")
      store.put_fact(tenant: "acme:c-1", key: "pedido", value: "open")
      store.put_fact(tenant: "chat:acme:chat-1", key: "k", value: "v") # acme's session cell
      store.put_fact(tenant: "chat:globex:chat-1", key: "k", value: "v") # another tenant's

      expect(store.purge_tenant("acme")).to eq(3)
      expect(store.get_fact(tenant: "acme", key: "catalogo")).to be_nil
      expect(store.facts(tenant: "acme:c-1")).to be_empty
      expect(store.facts(tenant: "chat:acme:chat-1")).to be_empty
      expect(store.get_fact(tenant: "chat:globex:chat-1", key: "k")).not_to be_nil # untouched
    end
  end
end
