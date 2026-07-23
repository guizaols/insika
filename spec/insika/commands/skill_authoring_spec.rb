# frozen_string_literal: true

require "spec_helper"

# Phase 4 Stage C: authoring commands for shared skills.
RSpec.describe "Skill authoring commands (Phase 4 Stage C)" do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:source) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:catalog) { Insika::SkillCatalog.new([], store: skill_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(type, payload) = Insika::Command.build(type, payload)
  def skill_md(name, body = "body") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  describe Insika::Commands::WriteSkill do
    subject(:handler) { described_class.new(skill_store: skill_store, skill_catalog: catalog, event_stream: stream) }

    it "writes the skill, reloads the catalog (hot) and emits :skill_written" do
      expect(catalog.find("pedido")).to be_nil
      res = handler.call(cmd(:write_skill, { "name" => "pedido", "content" => skill_md("pedido", "faz pedido") }))
      expect(res[:name]).to eq("pedido")
      expect(catalog.find("pedido").body).to eq("faz pedido") # reload already applied
      expect(events.map(&:type)).to eq([:skill_written])
    end

    it "name required; frontmatter without name -> ValidationError" do
      expect { handler.call(cmd(:write_skill, { "content" => skill_md("x") })) }
        .to raise_error(Insika::ValidationError, /name/)
      expect { handler.call(cmd(:write_skill, { "name" => "p", "content" => "sem frontmatter" })) }
        .to raise_error(Insika::ValidationError, /frontmatter/)
    end

    # Regression (a real merchant pack): a description with `: ` in the prose broke
    # strict YAML -> Psych::SyntaxError (500). Now the tolerant parser accepts it.
    it "accepts frontmatter with `: ` in the description prose (does not raise Psych)" do
      content = "---\nname: gift\ndescription: Discovery. Chocolate/gift: there is NO size gate. Enable it in the briefing.\n---\nbody\n"
      expect { handler.call(cmd(:write_skill, { "name" => "gift", "content" => content })) }.not_to raise_error
      expect(catalog.find("gift").description).to include("gift: there is NO size gate")
    end
  end

  describe Insika::Commands::SetSkillAgents do
    subject(:handler) { described_class.new(profile_source: source, event_stream: stream) }

    before do
      source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[cardapio]))
      source.put(Insika::AgentProfile.build(id: "chef", model: "m", skills: []))
      source.put(Insika::AgentProfile.build(id: "geral", model: "m", skills: nil)) # todas
    end

    it "enables the skill on the listed agents (adds to the explicit allowlist)" do
      res = handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia chef] }))
      expect(source.fetch("bia").skills).to contain_exactly("cardapio", "pedido")
      expect(source.fetch("chef").skills).to eq(%w[pedido])
      expect(res[:enabled_for]).to contain_exactly("bia", "chef")
      expect(events.map(&:type)).to include(:skill_agents_set)
    end

    it "disables it on the NON-listed ones that had the skill explicitly" do
      source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[cardapio pedido]))
      handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[chef] }))
      expect(source.fetch("bia").skills).to eq(%w[cardapio]) # pedido removed
    end

    it "an agent with skills=nil (all) stays intact and goes into skipped_all when disabling" do
      res = handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia] }))
      expect(source.fetch("geral").skills).to be_nil            # did not materialize an allowlist
      expect(res[:skipped_all]).to include("geral")
    end

    it "name required; non-list agent_ids -> ValidationError" do
      expect { handler.call(cmd(:set_skill_agents, { "agent_ids" => [] })) }.to raise_error(Insika::ValidationError, /name/)
      expect { handler.call(cmd(:set_skill_agents, { "name" => "p", "agent_ids" => "x" })) }
        .to raise_error(Insika::ValidationError, /list/)
    end
  end
end
