# frozen_string_literal: true

require "spec_helper"

# Phase 4 Stage D (task 9 / D5): the agent's memory becomes editable via Command
# (HTTP), not only through the `remember` tool within the turn.
RSpec.describe "Memory commands (Phase 4 Stage D)" do
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
end
