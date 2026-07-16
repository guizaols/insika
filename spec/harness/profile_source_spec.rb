# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Harness ProfileSource (Fase 4 D2)" do
  let(:profile) do
    Harness::AgentProfile.build(
      id: "bia", model: "deepseek-chat", provider: :deepseek,
      tools_allow: %w[menu calc], skills: %w[pedido],
      policies: %i[tool_allowlist skill_allowlist], memory: true,
      limits: { tool_timeout: 30, turn_timeout: 120 }
    )
  end

  describe Harness::StaticProfileSource do
    subject(:src) { described_class.new({ "bia" => profile }) }

    it "[] e fetch devolvem o profile; nil se ausente (não levanta)" do
      expect(src["bia"]).to eq(profile)
      expect(src.fetch("bia")).to eq(profile)
      expect(src["sumiu"]).to be_nil
    end

    it "all/ids" do
      expect(src.all).to eq([profile])
      expect(src.ids).to eq(["bia"])
    end
  end

  describe Harness::StoredProfileSource do
    let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
    subject(:src) { described_class.new(config_store: config_store) }

    it "put -> fetch faz round-trip PRESERVANDO os symbols (provider/policies/limits)" do
      src.put(profile)
      got = src.fetch("bia")

      # o ponto crítico do D2: JSON round-trip vira string; re-simbolizamos.
      expect(got.provider).to eq(:deepseek)                       # symbol, não "deepseek"
      expect(got.policies).to eq(%i[tool_allowlist skill_allowlist]) # symbols
      expect(got.limits[:tool_timeout]).to eq(30)                 # chave symbol + Integer
      expect(got.limits[:turn_timeout]).to eq(120)
      expect(got.tools_allow).to eq(%w[menu calc])
      expect(got.skills).to eq(%w[pedido])
      expect(got.memory).to be(true)
      # limits ganha os defaults no build (merge)
      expect(got.limits[:max_turns]).to eq(Harness::AgentProfile::DEFAULT_LIMITS[:max_turns])
    end

    it "fetch de ausente -> nil; all/ids refletem o store" do
      expect(src.fetch("nope")).to be_nil
      src.put(profile)
      expect(src.ids).to eq(["bia"])
      expect(src.all.map(&:id)).to eq(["bia"])
    end

    it "delete remove o profile" do
      src.put(profile)
      expect(src.delete("bia")).to be(true)
      expect(src.fetch("bia")).to be_nil
    end

    it "cada fetch lê FRESCO (edição vale sem reconstruir a source)" do
      src.put(profile)
      src.put(Harness::AgentProfile.build(id: "bia", model: "novo-modelo"))
      expect(src.fetch("bia").model).to eq("novo-modelo")
    end

    it "round-trip de metadata (store_id do contexto de turno, Fase 6)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m", metadata: { store_id: "loja-7" }))
      got = src.fetch("loja")
      expect(got.store_id).to eq("loja-7") # sobrevive ao JSON round-trip (chave vira string)
    end

    it "round-trip de tools_allow_groups (Fase 7/D4/F5, Etapa C)" do
      src.put(Harness::AgentProfile.build(id: "loja", model: "m", tools_allow_groups: %w[b2b natura]))
      expect(src.fetch("loja").tools_allow_groups).to eq(%w[b2b natura])
    end
  end

  describe ".coerce" do
    it "Hash -> StaticProfileSource; ProfileSource passa direto" do
      static = Harness::ProfileSource.coerce({ "bia" => profile })
      expect(static).to be_a(Harness::StaticProfileSource)
      expect(static["bia"]).to eq(profile)

      stored = Harness::StoredProfileSource.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new))
      expect(Harness::ProfileSource.coerce(stored)).to be(stored)
    end

    it "nil -> StaticProfileSource vazio (paridade com Hash vazio)" do
      expect(Harness::ProfileSource.coerce(nil)["x"]).to be_nil
    end
  end
end
