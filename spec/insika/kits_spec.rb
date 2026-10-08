# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Kits do
  let(:kits) do
    { "grocery" => { "description" => "", "skills" => %w[substitution], "tools" => %w[add_to_cart],
                     "tool_groups" => %w[mcp:crm] } }
  end

  def agent(**attrs) = Insika::AgentProfile.build(id: "bia", model: "m", **attrs)

  it "unions kit tools, groups and skills into an explicit allowlist" do
    p = described_class.apply(agent(tools_allow: %w[menu], skills: %w[pedido], kits: %w[grocery]), kits)
    expect(p.tools_allow).to eq(%w[menu add_to_cart])
    expect(p.tools_allow_groups).to eq(%w[mcp:crm])
    expect(p.skills).to eq(%w[pedido substitution])
  end

  it "never narrows an 'all' agent" do
    p = described_class.apply(agent(tools_allow: nil, skills: nil, kits: %w[grocery]), kits)
    expect(p.tools_allow).to be_nil
    expect(p.tools_allow_groups).to be_nil
    expect(p.skills).to be_nil
  end

  it "keeps group-only agents as a union (tools_allow nil, groups set)" do
    p = described_class.apply(agent(tools_allow: nil, tools_allow_groups: %w[default], kits: %w[grocery]), kits)
    expect(p.tools_allow).to eq(%w[add_to_cart])
    expect(p.tools_allow_groups).to eq(%w[default mcp:crm])
  end

  it "ignores a kit that no longer exists" do
    a = agent(tools_allow: %w[menu], kits: %w[gone])
    expect(described_class.apply(a, kits)).to be(a)
  end

  it "returns the same profile when the agent has no kits" do
    a = agent(tools_allow: %w[menu])
    expect(described_class.apply(a, kits)).to be(a)
  end

  it "validates the name and normalizes the lists" do
    expect(described_class.validate!("grocery", "skills" => ["a", "a", " "], "tools" => nil))
      .to eq("description" => "", "skills" => %w[a], "tools" => [], "tool_groups" => [])
    expect { described_class.validate!("Bad Name", {}) }.to raise_error(Insika::ValidationError)
    expect { described_class.validate!("ok", "tools" => "x") }.to raise_error(Insika::ValidationError)
  end

  it "skips a malformed kit instead of failing the turn" do
    a = agent(tools_allow: %w[menu], kits: %w[grocery broken])
    p = described_class.apply(a, kits.merge("broken" => ["x"]))
    expect(p.tools_allow).to eq(%w[menu add_to_cart])
  end
end
