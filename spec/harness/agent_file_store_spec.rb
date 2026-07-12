# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa C: workspace por agente (conteúdo de prompt no Store durável).
RSpec.describe Harness::AgentFileStore do
  subject(:store) { described_class.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }

  it "write/read round-trip por agente e por arquivo" do
    store.write("bia", "IDENTITY.md", "Sou a Bia.")
    store.write("chef", "IDENTITY.md", "Sou o Chef.")

    expect(store.read("bia", "IDENTITY.md")).to eq("Sou a Bia.")
    expect(store.read("chef", "IDENTITY.md")).to eq("Sou o Chef.")   # isolado por agente
    expect(store.read("bia", "SOUL.md")).to be_nil                    # arquivo inexistente
    expect(store.read("nope", "IDENTITY.md")).to be_nil               # agente inexistente
  end

  it "list -> nomes ordenados do agente" do
    store.write("bia", "SOUL.md", "s")
    store.write("bia", "IDENTITY.md", "i")
    expect(store.list("bia")).to eq(%w[IDENTITY.md SOUL.md])
    expect(store.list("vazio")).to eq([])
  end

  it "sobrescrever versiona o conteúdo anterior em history (mais recente primeiro)" do
    store.write("bia", "IDENTITY.md", "v1")
    store.write("bia", "IDENTITY.md", "v2")
    store.write("bia", "IDENTITY.md", "v3")

    expect(store.read("bia", "IDENTITY.md")).to eq("v3")
    expect(store.versions("bia", "IDENTITY.md").map { |h| h["content"] }).to eq(%w[v2 v1])
  end

  it "create_only recusa sobrescrever arquivo existente" do
    store.write("bia", "IDENTITY.md", "v1")
    expect { store.write("bia", "IDENTITY.md", "v2", create_only: true) }
      .to raise_error(Harness::ValidationError, /já existe/)
    expect(store.read("bia", "IDENTITY.md")).to eq("v1")
  end

  it "delete -> bool (existia?) e some do list" do
    store.write("bia", "IDENTITY.md", "v1")
    expect(store.delete("bia", "IDENTITY.md")).to be(true)
    expect(store.delete("bia", "IDENTITY.md")).to be(false)
    expect(store.read("bia", "IDENTITY.md")).to be_nil
  end

  describe "#restore" do
    before do
      store.write("bia", "IDENTITY.md", "v1")
      store.write("bia", "IDENTITY.md", "v2")
    end

    it "restaura uma versão antiga como conteúdo atual (nova escrita)" do
      store.restore("bia", "IDENTITY.md", 0) # v1 (mais recente antiga)
      expect(store.read("bia", "IDENTITY.md")).to eq("v1")
      # v2 (o que estava atual) entra no topo do history
      expect(store.versions("bia", "IDENTITY.md").map { |h| h["content"] }).to eq(%w[v2 v1])
    end

    it "índice inválido -> ValidationError; arquivo inexistente -> NotFoundError" do
      expect { store.restore("bia", "IDENTITY.md", 9) }.to raise_error(Harness::ValidationError)
      expect { store.restore("bia", "SUMIU.md", 0) }.to raise_error(Harness::NotFoundError)
    end
  end

  it "history respeita o teto HISTORY_MAX" do
    (0..(described_class::HISTORY_MAX + 3)).each { |i| store.write("bia", "f.md", "v#{i}") }
    expect(store.versions("bia", "f.md").length).to eq(described_class::HISTORY_MAX)
  end
end
