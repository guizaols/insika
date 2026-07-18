# frozen_string_literal: true

require "spec_helper"
require "harness/tools/load_skill" # loaded lazily in production; explicit in the test

RSpec.describe Harness::Tools::LoadSkill do
  # Catalog double with the surface used (find -> Skill|nil).
  Skill = Struct.new(:name, :body)

  let(:catalog) do
    instance_double("Harness::SkillCatalog").tap do |c|
      allow(c).to receive(:find) { |name| name == "cardapio" ? Skill.new("cardapio", "CORPO") : nil }
    end
  end

  it "returns the skill body when allowed and present" do
    tool = described_class.new(catalog, ["cardapio"])

    expect(tool.execute(name: "cardapio")).to eq("CORPO")
  end

  it "refuses a skill outside the allowlist (without raising)" do
    tool = described_class.new(catalog, ["pedido"])

    expect(tool.execute(name: "cardapio")).to eq({ error: "skill 'cardapio' not available for this agent" })
  end

  it "reports a skill that is allowed but nonexistent in the catalog" do
    tool = described_class.new(catalog, ["fantasma"])

    expect(tool.execute(name: "fantasma")).to eq({ error: "skill 'fantasma' not found" })
  end
end
