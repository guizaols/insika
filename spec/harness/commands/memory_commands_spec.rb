# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa D (task 9 / D5): a memória do agente vira editável por Command
# (HTTP), não só via tool `remember` dentro do turno.
RSpec.describe "Commands de memória (Fase 4 Etapa D)" do
  let(:store) { Harness::MemoryStore.new(store: Harness::Stores::Memory.new) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload, tenant: nil) = Harness::Command.build(type, payload, tenant: tenant)

  describe Harness::Commands::MemoryPutFact do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "grava o fato; emite :memory_fact_put; devolve o Fact" do
      fact = handler.call(cmd(:memory_put_fact, { "tenant" => "acme", "key" => "nome", "value" => "Bia" }))
      expect(fact.key).to eq("nome")
      expect(fact.value).to eq("Bia")
      expect(store.get_fact(tenant: "acme", key: "nome").value).to eq("Bia")
      expect(events.map(&:type)).to eq([:memory_fact_put])
    end

    it "usa o tenant do meta quando não vem no payload" do
      handler.call(cmd(:memory_put_fact, { "key" => "k", "value" => "v" }, tenant: "t1"))
      expect(store.get_fact(tenant: "t1", key: "k").value).to eq("v")
    end

    it "key e value obrigatórios" do
      expect { handler.call(cmd(:memory_put_fact, { "value" => "v" })) }.to raise_error(Harness::ValidationError, /key/)
      expect { handler.call(cmd(:memory_put_fact, { "key" => "k" })) }.to raise_error(Harness::ValidationError, /value/)
    end
  end

  describe Harness::Commands::MemoryForgetFact do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "remove o fato existente (existed: true) e emite" do
      store.put_fact(tenant: "acme", key: "nome", value: "Bia")
      result = handler.call(cmd(:memory_forget_fact, { "tenant" => "acme", "key" => "nome" }))
      expect(result).to eq({ existed: true })
      expect(store.get_fact(tenant: "acme", key: "nome")).to be_nil
      expect(events.map(&:type)).to eq([:memory_fact_forgotten])
    end

    it "idempotente: esquecer inexistente -> existed: false (não é erro)" do
      expect(handler.call(cmd(:memory_forget_fact, { "key" => "nope" }))).to eq({ existed: false })
    end

    it "key obrigatório" do
      expect { handler.call(cmd(:memory_forget_fact, {})) }.to raise_error(Harness::ValidationError, /key/)
    end
  end

  describe Harness::Commands::MemoryAddNote do
    subject(:handler) { described_class.new(memory_store: store, event_stream: stream) }

    it "acrescenta a nota; emite :memory_note_added; devolve o Note" do
      note = handler.call(cmd(:memory_add_note, { "tenant" => "acme", "text" => "cliente prefere pizza" }))
      expect(note.text).to eq("cliente prefere pizza")
      expect(store.notes(tenant: "acme").map(&:text)).to include("cliente prefere pizza")
      expect(events.map(&:type)).to eq([:memory_note_added])
    end

    it "text obrigatório" do
      expect { handler.call(cmd(:memory_add_note, { "text" => "" })) }.to raise_error(Harness::ValidationError, /text/)
    end
  end
end
