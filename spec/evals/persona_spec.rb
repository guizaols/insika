# frozen_string_literal: true

require "spec_helper"

# The simulated customer (RFC-0014 PR2). The persona is the WHOLE instruction a
# model plays the customer with; validation is the guardrail — a persona without
# `knows` or `max_turns` would simulate nothing.
RSpec.describe Insika::Evals::PersonaLoader do
  def build(overrides = {})
    described_class.build({
      "goal" => "find a gift under R$100", "style" => "short messages",
      "opens_with" => "oi, queria um presente",
      "knows" => { "budget" => "100", "occasion" => "birthday" },
      "max_turns" => 8
    }.merge(overrides))
  end

  it "builds a valid persona" do
    p = build
    expect(p.goal).to eq("find a gift under R$100")
    expect(p.opens_with).to eq("oi, queria um presente")
    expect(p.knows).to eq("budget" => "100", "occasion" => "birthday")
    expect(p.max_turns).to eq(8)
  end

  it "rejects a missing goal" do
    expect { build("goal" => "") }.to raise_error(described_class::InvalidPersona, /'goal'/)
  end

  it "rejects a missing or empty knows" do
    expect { build("knows" => nil) }.to raise_error(described_class::InvalidPersona, /'knows'/)
    expect { build("knows" => {}) }.to raise_error(described_class::InvalidPersona, /'knows'/)
    expect { build("knows" => "not-a-map") }.to raise_error(described_class::InvalidPersona, /'knows'/)
  end

  it "rejects a missing opens_with" do
    expect { build("opens_with" => nil) }.to raise_error(described_class::InvalidPersona, /'opens_with'/)
  end

  it "rejects a missing or non-positive max_turns" do
    expect { build("max_turns" => nil) }.to raise_error(described_class::InvalidPersona, /'max_turns'/)
    expect { build("max_turns" => 0) }.to raise_error(described_class::InvalidPersona, /'max_turns'/)
    expect { build("max_turns" => "eight") }.to raise_error(described_class::InvalidPersona, /'max_turns'/)
  end

  it "normalizes knows to string keys and values" do
    p = build("knows" => { budget: 100, occasion: :birthday })
    expect(p.knows).to eq("budget" => "100", "occasion" => "birthday")
  end

  describe "#prompt" do
    it "states the anti-invention rule: the knows facts are the ONLY assertions" do
      p = build
      prompt = p.prompt([{ role: "user", text: "oi" }])
      expect(prompt).to include("GOAL: find a gift under R$100")
      expect(prompt).to include("- budget: 100")
      expect(prompt).to include("You may ONLY assert the facts above")
      expect(prompt).to include("Never invent")
      expect(prompt).to include("<<goal_met>>")
      expect(prompt).to include("<<gave_up>>")
      expect(prompt).to include("user: oi")
    end
  end
end

# Persona within the Golden shape: a case is ONE of two shapes — turns or persona.
RSpec.describe Insika::Evals::GoldenLoader do
  def case_with(extra = {})
    described_class.build({
      "id" => "c", "agent" => "bia",
      "persona" => { "goal" => "g", "knows" => { "a" => "b" },
                     "opens_with" => "oi", "max_turns" => 4 },
      "expect" => {}
    }.merge(extra))
  end

  it "builds a simulated case from a persona key" do
    g = case_with
    expect(g.simulated?).to be(true)
    expect(g.persona).to be_a(Insika::Evals::Persona)
    expect(g.user_turns).to eq([])
    expect(g.opens_with).to eq("oi")
  end

  it "refuses a case with BOTH turns and persona" do
    expect { case_with("turns" => [{ "user" => "oi" }]) }
      .to raise_error(described_class::InvalidGolden, /ONE shape/)
  end

  it "wraps a malformed persona as an InvalidGolden" do
    expect { case_with("persona" => { "goal" => "g" }) }
      .to raise_error(described_class::InvalidGolden, /'knows'/)
  end
end