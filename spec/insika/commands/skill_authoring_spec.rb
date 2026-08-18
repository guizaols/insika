# frozen_string_literal: true

require "spec_helper"

# authoring commands for skills, shared and per-agent.
RSpec.describe "Skill authoring commands" do
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

    # Specializing is a write into the AGENT's scope. The shared record is untouched,
    # so the skill stays shared for everybody who did not specialize it.
    it "`agent` writes the specialization and leaves the shared skill alone" do
      handler.call(cmd(:write_skill, { "name" => "esc", "content" => skill_md("esc", "na biro") }))
      res = handler.call(cmd(:write_skill, { "name" => "esc", "agent" => "kino",
                                            "content" => skill_md("esc", "na kino a troca") }))

      expect(res[:agent]).to eq("kino")
      expect(catalog.find("esc", agent: "kino").body).to eq("na kino a troca")
      expect(catalog.find("esc").body).to eq("na biro")
      expect(events.last.data).to include(name: "esc", agent: "kino")
    end
  end

  describe Insika::Commands::DeleteSkill do
    subject(:handler) { described_class.new(skill_store: skill_store, skill_catalog: catalog, event_stream: stream) }

    before { skill_store.write("esc", skill_md("esc", "shared")) }

    it "deletes a shared skill and reloads the catalog" do
      expect(handler.call(cmd(:delete_skill, { "name" => "esc" }))[:deleted]).to be(true)
      expect(catalog.find("esc")).to be_nil
    end

    # "Stop specializing this" must not be expressible as "delete the skill": the agent
    # falls back to the shared body, which is still there.
    it "deleting the specialization leaves the shared skill, and the agent falls back to it" do
      skill_store.write("esc", skill_md("esc", "mine"), agent: "kino")
      catalog.reload

      handler.call(cmd(:delete_skill, { "name" => "esc", "agent" => "kino" }))

      expect(catalog.find("esc", agent: "kino").body).to eq("shared")
    end

    it "a skill that is not there -> NotFoundError; name required -> ValidationError" do
      expect { handler.call(cmd(:delete_skill, { "name" => "fantasma" })) }.to raise_error(Insika::NotFoundError)
      expect { handler.call(cmd(:delete_skill, { "name" => "esc", "agent" => "ninguem" })) }
        .to raise_error(Insika::NotFoundError, /for agent 'ninguem'/)
      expect { handler.call(cmd(:delete_skill, {})) }.to raise_error(Insika::ValidationError, /name/)
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
      expect { handler.call(cmd(:set_skill_agents, { "name" => "p", "eager_ids" => "x" })) }
        .to raise_error(Insika::ValidationError, /list/)
    end

    # Eagerness is the second per-agent decision about the same shared skill, so it is
    # the same screen and the same command.
    describe "eager_ids" do
      it "marks the skill always-on for the listed agents only" do
        res = handler.call(cmd(:set_skill_agents,
                               { "name" => "pedido", "agent_ids" => %w[bia chef], "eager_ids" => %w[bia] }))

        expect(source.fetch("bia").skills_eager).to eq(%w[pedido])
        expect(source.fetch("chef").skills_eager).to eq([])
        expect(res[:eager_for]).to eq(%w[bia])
      end

      # The whole point of moving eagerness off the skill: one shared skill, two agents,
      # two answers.
      it "the same shared skill is always-on for one agent and discretionary for another" do
        handler.call(cmd(:set_skill_agents,
                         { "name" => "pedido", "agent_ids" => %w[bia chef], "eager_ids" => %w[bia] }))

        expect(source.fetch("bia").skills_eager).to eq(%w[pedido])
        expect(source.fetch("chef").skills).to include("pedido")
        expect(source.fetch("chef").skills_eager).to eq([])
      end

      it "unchecking removes only that name, leaving the rest of the eager set" do
        source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[cardapio pedido],
                                              skills_eager: %w[cardapio pedido]))

        handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia], "eager_ids" => [] }))

        expect(source.fetch("bia").skills_eager).to eq(%w[cardapio])
      end

      # ABSENT is not the same request as EMPTY: a form that does not manage eagerness
      # must not silently clear it.
      it "an absent eager_ids leaves every agent's setting untouched" do
        source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[pedido], skills_eager: %w[pedido]))

        handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia] }))

        expect(source.fetch("bia").skills_eager).to eq(%w[pedido])
      end

      # Same reasoning as skipped_all: removing ONE name from a blanket `true` would
      # mean materializing the whole catalog as a list — a destructive surprise.
      it "an agent with blanket eager is left intact and reported" do
        source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[pedido], skills_eager: true))

        res = handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia], "eager_ids" => [] }))

        expect(source.fetch("bia").skills_eager).to be(true)
        expect(res[:skipped_eager_all]).to eq(%w[bia])
      end

      # Regression: the "no change" early return used to compare only `skills`, so an
      # eager-only edit on an agent whose allowlist was already right wrote nothing.
      it "persists an eager-only change (the allowlist did not move)" do
        source.put(Insika::AgentProfile.build(id: "bia", model: "m", skills: %w[pedido]))

        handler.call(cmd(:set_skill_agents, { "name" => "pedido", "agent_ids" => %w[bia], "eager_ids" => %w[bia] }))

        expect(source.fetch("bia").skills_eager).to eq(%w[pedido])
      end
    end
  end
end
