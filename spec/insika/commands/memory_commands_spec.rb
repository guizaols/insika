# frozen_string_literal: true

require "spec_helper"

# the agent's memory becomes editable via Command
# (HTTP), not only through the `remember` tool within the turn.
RSpec.describe "Memory commands" do
  let(:store) { Insika::MemoryStore.new(store: Insika::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload, tenant: nil) = Insika::Command.build(type, payload, tenant: tenant)

  describe Insika::Commands::MemoryPutFact do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "stores the fact; emits :memory_fact_put; returns the Fact" do
      fact = handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "key" => "nome", "value" => "Bia" }))
      expect(fact.key).to eq("nome")
      expect(fact.value).to eq("Bia")
      expect(store.get_fact(tenant: "acme", key: "nome").value).to eq("Bia")
      expect(events.map(&:type)).to eq([:memory_fact_put])
    end

    it "uses the tenant from meta when not present in the payload" do
      handler.call(cmd(:memory_put_fact, { "key" => "k", "value" => "v" }, tenant: "t1"))
      expect(store.get_fact(tenant: "t1", key: "k").value).to eq("v")
    end

    it "key and value are required" do
      expect { handler.call(cmd(:memory_put_fact, { "value" => "v" })) }.to raise_error(Insika::ValidationError, /key/)
      expect { handler.call(cmd(:memory_put_fact, { "key" => "k" })) }.to raise_error(Insika::ValidationError, /value/)
    end
  end

  describe Insika::Commands::MemoryForgetFact do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "removes the existing fact (existed: true) and emits" do
      store.put_fact(tenant: "acme", key: "nome", value: "Bia")
      result = handler.call(cmd(:memory_forget_fact, { "tenant" => "acme", "key" => "nome" }))
      expect(result).to eq({ existed: true })
      expect(store.get_fact(tenant: "acme", key: "nome")).to be_nil
      expect(events.map(&:type)).to eq([:memory_fact_forgotten])
    end

    it "idempotent: forgetting a nonexistent one -> existed: false (not an error)" do
      expect(handler.call(cmd(:memory_forget_fact, { "key" => "nope" }))).to eq({ existed: false })
    end

    it "key required" do
      expect { handler.call(cmd(:memory_forget_fact, {})) }.to raise_error(Insika::ValidationError, /key/)
    end
  end

  describe Insika::Commands::MemoryAddNote do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "appends the note; emits :memory_note_added; returns the Note" do
      note = handler.call(cmd(:memory_add_note, { "tenant" => "acme", "text" => "cliente prefere pizza" }))
      expect(note.text).to eq("cliente prefere pizza")
      expect(store.notes(tenant: "acme").map(&:text)).to include("cliente prefere pizza")
      expect(events.map(&:type)).to eq([:memory_note_added])
    end

    it "text required" do
      expect { handler.call(cmd(:memory_add_note, { "text" => "" })) }.to raise_error(Insika::ValidationError, /text/)
    end
  end

  describe "(customer + origin + audit)" do
    let(:audit_store) { Insika::MemoryAuditStore.new(store: Insika::Stores::Memory.new) }

    describe Insika::Commands::MemoryPutFact do
      it "put with customer: lands in the customer cell; event carries the customer; audit has old/new hashes + actor" do
        handler = described_class.new(memory_store: store, event_stream: stream, audit_store: audit_store)
        fact = handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "customer" => "c-1",
                                                     "key" => "size", "value" => "M", "operator" => "studio" }))
        expect(store.get_fact(tenant: "acme", customer: "c-1", key: "size").value).to eq("M")
        expect(fact.origin).to eq("operator")

        entry = audit_store.for_cell("memory:acme:c-1").first
        expect(entry.action).to eq("put")
        expect(entry.actor).to eq("studio")
        expect(entry.key).to eq("size")
        expect(entry.tenant).to eq("acme")
        expect(entry.customer).to eq("c-1")
        expect(entry.old_hash).to be_nil
        expect(entry.new_hash).to eq(Insika::MemoryAuditStore.digest("M"))

        expect(events.first.data[:customer]).to eq("c-1")
      end

      it "an update writes the old value's digest as old_hash" do
        store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
        handler = described_class.new(memory_store: store, event_stream: stream, audit_store: audit_store)
        handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "customer" => "c-1",
                                              "key" => "size", "value" => "L", "operator" => "studio" }))
        entry = audit_store.for_cell("memory:acme:c-1").first
        expect(entry.old_hash).to eq(Insika::MemoryAuditStore.digest("M"))
        expect(entry.new_hash).to eq(Insika::MemoryAuditStore.digest("L"))
      end

      it "expires_at round-trips; invalid raises through the store" do
        handler = described_class.new(memory_store: store, event_stream: stream, audit_store: audit_store)
        handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "customer" => "c-1", "key" => "k",
                                              "value" => "v", "expires_at" => "2026-12-31T00:00:00Z",
                                              "operator" => "studio" }))
        expect(store.get_fact(tenant: "acme", customer: "c-1", key: "k").expires_at).not_to be_nil

        expect {
          handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "customer" => "c-1", "key" => "k",
                                                "value" => "v", "expires_at" => "nope", "operator" => "studio" }))
        }.to raise_error(Insika::ValidationError, /expires_at/)
      end

      it "without customer:/audit_store: is byte-identical to today (no audit, no customer in the event)" do
        handler = described_class.new(memory_store: store, event_stream: stream)
        fact = handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "key" => "k", "value" => "v" }))
        expect(fact.key).to eq("k")
        expect(events.first.data[:customer]).to be_nil
        expect(audit_store.for_cell("memory:acme")).to eq([])
      end
    end

    describe Insika::Commands::MemoryForgetFact do
      it "forget writes the audit line with old_hash only" do
        store.put_fact(tenant: "acme", customer: "c-1", key: "size", value: "M")
        handler = described_class.new(memory_store: store, event_stream: stream, audit_store: audit_store)
        result = handler.call(cmd(:memory_forget_fact, { "tenant" => "acme", "customer" => "c-1",
                                                          "key" => "size", "operator" => "studio" }))
        expect(result).to eq({ existed: true })
        expect(store.get_fact(tenant: "acme", customer: "c-1", key: "size")).to be_nil

        entry = audit_store.for_cell("memory:acme:c-1").first
        expect(entry.action).to eq("forget")
        expect(entry.old_hash).to eq(Insika::MemoryAuditStore.digest("M"))
        expect(entry.new_hash).to be_nil
      end
    end
  end
end
