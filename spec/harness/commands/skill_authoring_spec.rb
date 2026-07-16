# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa C: Commands de autoria de skills compartilhadas.
RSpec.describe "Commands de autoria de skills (Fase 4 Etapa C)" do
  let(:config_store) { Harness::ConfigStore.new(store: Harness::Stores::Memory.new) }
  let(:source) { Harness::StoredProfileSource.new(config_store: config_store) }
  let(:skill_store) { Harness::SkillStore.new(config_store: config_store) }
  let(:catalog) { Harness::SkillCatalog.new([], store: skill_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Harness::Command.build(type, payload)
  def skill_md(name, body = "corpo") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  describe Harness::Commands::WriteSkill do
    subject(:handler) { described_class.new(skill_store: skill_store, skill_catalog: catalog, event_stream: stream) }

    it "grava a skill, recarrega o catálogo (hot) e emite :skill_written" do
      expect(catalog.find("pedido")).to be_nil
      res = handler.call(cmd(:write_skill, { "name" => "pedido", "content" => skill_md("pedido", "faz pedido") }))
      expect(res[:name]).to eq("pedido")
      expect(catalog.find("pedido").body).to eq("faz pedido") # reload já aplicou
      expect(events.map(&:type)).to eq([:skill_written])
    end

    it "name obrigatório; frontmatter sem name -> ValidationError" do
      expect { handler.call(cmd(:write_skill, { "content" => skill_md("x") })) }
        .to raise_error(Harness::ValidationError, /name/)
      expect { handler.call(cmd(:write_skill, { "name" => "p", "content" => "sem frontmatter" })) }
        .to raise_error(Harness::ValidationError, /frontmatter/)
    end

    # Regressão (pack real cacau-show): description com `: ` na prosa quebrava o
    # YAML estrito -> Psych::SyntaxError (500). Agora o parser tolerante aceita.
    it "aceita frontmatter com `: ` na prosa do description (não levanta Psych)" do
      content = "---\nname: gift\ndescription: Discovery. Chocolate/presente: NÃO há size gate. Ative no briefing.\n---\ncorpo\n"
      expect { handler.call(cmd(:write_skill, { "name" => "gift", "content" => content })) }.not_to raise_error
      expect(catalog.find("gift").description).to include("presente: NÃO há size gate")
    end
  end

  describe Harness::Commands::SetSkillAgents do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    before do
      source.put(Harness::AgentProfile.build(id: "bia", model: "m", skills: %w[cardapio]))
      source.put(Harness::AgentProfile.build(id: "chef", model: "m", skills: []))
      source.put(Harness::AgentProfile.build(id: "geral", model: "m", skills: nil)) # todas
    end

    it "habilita a skill nos agentes listados (adiciona à allowlist explícita)" do
      res = handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia chef] }))
      expect(source.fetch("bia").skills).to contain_exactly("cardapio", "pedido")
      expect(source.fetch("chef").skills).to eq(%w[pedido])
      expect(res[:enabled_for]).to contain_exactly("bia", "chef")
      expect(events.map(&:type)).to include(:skill_agents_set)
    end

    it "desabilita nos NÃO listados que tinham a skill explícita" do
      source.put(Harness::AgentProfile.build(id: "bia", model: "m", skills: %w[cardapio pedido]))
      handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[chef] }))
      expect(source.fetch("bia").skills).to eq(%w[cardapio]) # pedido removido
    end

    it "agente com skills=nil (todas) fica intacto e entra em skipped_all ao desabilitar" do
      res = handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia] }))
      expect(source.fetch("geral").skills).to be_nil            # não materializou allowlist
      expect(res[:skipped_all]).to include("geral")
    end

    it "name obrigatório; agent_ids não-lista -> ValidationError" do
      expect { handler.call(cmd(:set_skill_agents, { "agent_ids" => [] })) }.to raise_error(Harness::ValidationError, /name/)
      expect { handler.call(cmd(:set_skill_agents, { "name" => "p", "agent_ids" => "x" })) }
        .to raise_error(Harness::ValidationError, /lista/)
    end
  end
end
