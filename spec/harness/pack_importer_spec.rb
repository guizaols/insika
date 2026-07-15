# frozen_string_literal: true

require "spec_helper"

# Fase 6/D4/F6 (task 7) — o importador emite os Commands de autoria a partir de
# um Pack. Prova: create vs update (upsert), 1 write_agent_file por arquivo, 1
# write_skill por skill, 1 write_data_tool por tool, e allowlists AUTORITATIVAS
# derivadas do pack (isolamento por loja + NF2).
RSpec.describe Harness::PackImporter do
  # bus duplo: grava (type, payload) de cada dispatch.
  class BusSpy
    Dispatched = Struct.new(:type, :payload)
    attr_reader :calls

    def initialize = (@calls = [])
    def dispatch(command) = (@calls << Dispatched.new(command.type, command.payload); {})
    def of(type) = @calls.select { |c| c.type == type }
  end

  # ProfileSource duplo: só o fetch importa (existência p/ create vs update).
  def profiles(existing = {})
    src = Object.new
    src.define_singleton_method(:fetch) { |id| existing[id] }
    src.define_singleton_method(:[]) { |id| existing[id] }
    src
  end

  let(:bus) { BusSpy.new }

  def pack(**over)
    Harness::Pack.from_h({
      config: { id: "loja-7", model: "deepseek-chat", metadata: { store_id: "7" } },
      files: { "IDENTITY.md" => "quem sou", "SOUL.md" => "voz" },
      skills: { "escalation" => "---\nname: escalation\n---\n", "promo" => "---\nname: promo\n---\n" },
      tools: [{ "name" => "cart", "description" => "d", "request" => { "url" => "https://api.test" } },
              { "name" => "search", "description" => "d", "request" => { "url" => "https://api.test" } }]
    }.merge(over))
  end

  describe "#import (agente novo)" do
    subject(:result) { described_class.new(bus: bus, profiles: profiles).import(pack) }

    it "cria o agente (create_agent) com o manifesto do pack" do
      result
      create = bus.of(:create_agent)
      expect(create.size).to eq(1)
      expect(create.first.payload).to include(id: "loja-7", model: "deepseek-chat", metadata: { store_id: "7" })
    end

    it "deriva allowlists AUTORITATIVAS do pack (isolamento + NF2)" do
      result
      attrs = bus.of(:create_agent).first.payload
      expect(attrs[:prompt_files]).to contain_exactly("IDENTITY.md", "SOUL.md")
      expect(attrs[:skills]).to contain_exactly("escalation", "promo")
      expect(attrs[:tools_allow]).to contain_exactly("cart", "search")
    end

    it "1 write_agent_file por arquivo, com agent_id e conteúdo" do
      result
      files = bus.of(:write_agent_file)
      expect(files.map { |c| c.payload[:file] }).to contain_exactly("IDENTITY.md", "SOUL.md")
      expect(files).to all(have_attributes(payload: include(agent_id: "loja-7")))
      expect(files.find { |c| c.payload[:file] == "IDENTITY.md" }.payload[:content]).to eq("quem sou")
    end

    it "1 write_skill por skill + 1 write_data_tool por tool" do
      result
      expect(bus.of(:write_skill).map { |c| c.payload[:name] }).to contain_exactly("escalation", "promo")
      expect(bus.of(:write_data_tool).map { |c| c.payload["name"] }).to contain_exactly("cart", "search")
    end

    it "ordem: create_agent ANTES dos write_agent_file (o arquivo exige o agente)" do
      result
      types = bus.calls.map(&:type)
      expect(types.index(:create_agent)).to be < types.index(:write_agent_file)
    end

    it "-> resumo do que foi provisionado" do
      expect(result).to eq(
        agent_id: "loja-7", created: true,
        files: %w[IDENTITY.md SOUL.md], skills: %w[escalation promo], tools: %w[cart search]
      )
    end
  end

  describe "#import (agente existente = update/upsert)" do
    it "usa update_agent (não create) quando o agente já existe" do
      importer = described_class.new(bus: bus, profiles: profiles("loja-7" => Object.new))
      out = importer.import(pack)
      expect(bus.of(:create_agent)).to be_empty
      expect(bus.of(:update_agent).size).to eq(1)
      expect(out[:created]).to be(false)
    end
  end

  describe "allowlist com tools_allow no config" do
    it "une tools do config com as tools do pack (NF2)" do
      p = pack(config: { id: "loja-7", model: "m", tools_allow: %w[send_finalize] })
      described_class.new(bus: bus, profiles: profiles).import(p)
      expect(bus.of(:create_agent).first.payload[:tools_allow]).to contain_exactly("send_finalize", "cart", "search")
    end
  end

  describe "validação" do
    it "pack sem config.id -> ValidationError (não despacha nada)" do
      p = Harness::Pack.from_h(config: { model: "m" })
      expect { described_class.new(bus: bus, profiles: profiles).import(p) }
        .to raise_error(Harness::ValidationError, /config\.id/)
      expect(bus.calls).to be_empty
    end
  end

  describe "#delete" do
    it "despacha delete_agent" do
      out = described_class.new(bus: bus, profiles: profiles).delete("loja-7")
      expect(bus.of(:delete_agent).first.payload).to eq(id: "loja-7")
      expect(out).to eq(agent_id: "loja-7", deleted: true)
    end
  end
end
