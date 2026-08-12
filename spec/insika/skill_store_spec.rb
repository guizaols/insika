# frozen_string_literal: true

require "spec_helper"

# authored skills (SKILL.md in the durable Store), shared and per-agent.
RSpec.describe Insika::SkillStore do
  subject(:store) { described_class.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

  def skill_md(name, body = "body") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  it "write/get round-trip; names/all list the authored ones" do
    store.write("pedido", skill_md("pedido"))
    store.write("cardapio", skill_md("cardapio"))

    expect(store.get("pedido")).to eq(skill_md("pedido"))
    expect(store.names).to eq(%w[cardapio pedido])           # lexicographic
    expect(store.all.keys).to contain_exactly("pedido", "cardapio")
  end

  it "overwriting versions; create_only refuses" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    expect(store.versions("pedido").map { |h| h["content"] }).to eq([skill_md("pedido", "v1")])
    expect { store.write("pedido", skill_md("pedido"), create_only: true) }
      .to raise_error(Insika::ValidationError, /already exists/)
  end

  it "delete -> bool; restore reverts to an old version" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    store.restore("pedido", 0)
    expect(store.get("pedido")).to eq(skill_md("pedido", "v1"))
    expect(store.delete("pedido")).to be(true)
    expect(store.delete("pedido")).to be(false)
  end

  # The agent dimension is a SECOND ARGUMENT, never part of the key: a composite
  # "agent/name" would put a `/` inside what the Studio serves as one path segment.
  describe "the agent scope" do
    it "the same name holds a different body per agent, and the shared one is untouched" do
      store.write("escalation", skill_md("escalation", "shared"))
      store.write("escalation", skill_md("escalation", "for natura"), agent: "natura")

      expect(store.get("escalation")).to eq(skill_md("escalation", "shared"))
      expect(store.get("escalation", agent: "natura")).to eq(skill_md("escalation", "for natura"))
      expect(store.get("escalation", agent: "cacau")).to be_nil
    end

    it "an agent-private skill is invisible in the shared scope" do
      store.write("only-mine", skill_md("only-mine"), agent: "natura")

      expect(store.names).to eq([])
      expect(store.names(agent: "natura")).to eq(["only-mine"])
      expect(store.all(agent: "natura").keys).to eq(["only-mine"])
    end

    it "lists the agents that specialized something (what the catalog overlays)" do
      store.write("a", skill_md("a"))
      store.write("a", skill_md("a"), agent: "zeta")
      store.write("b", skill_md("b"), agent: "alpha")

      expect(store.agents).to eq(%w[alpha zeta])
    end

    it "versions, restores and create_only work per agent, independently of the shared record" do
      store.write("esc", skill_md("esc", "shared v1"))
      store.write("esc", skill_md("esc", "agent v1"), agent: "natura")
      store.write("esc", skill_md("esc", "agent v2"), agent: "natura")

      expect(store.versions("esc")).to eq([])                        # the shared one never changed
      expect(store.versions("esc", agent: "natura").map { |h| h["content"] }).to eq([skill_md("esc", "agent v1")])
      store.restore("esc", 0, agent: "natura")
      expect(store.get("esc", agent: "natura")).to eq(skill_md("esc", "agent v1"))
      expect { store.write("esc", skill_md("esc"), agent: "natura", create_only: true) }
        .to raise_error(Insika::ValidationError, /already exists for agent 'natura'/)
    end

    it "deleting the specialization leaves the shared skill in place" do
      store.write("esc", skill_md("esc", "shared"))
      store.write("esc", skill_md("esc", "mine"), agent: "natura")

      expect(store.delete("esc", agent: "natura")).to be(true)
      expect(store.delete("esc", agent: "natura")).to be(false)
      expect(store.get("esc")).to eq(skill_md("esc", "shared"))
    end
  end
end
