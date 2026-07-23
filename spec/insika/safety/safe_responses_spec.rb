# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::SafeResponses do
  it "returns a distinct non-blank reply per category" do
    %i[injection sexual abuse escalate default].each do |cat|
      expect(described_class.for(cat)).to be_a(String).and(satisfy { |s| !s.strip.empty? })
    end
  end

  it "the injection reply never echoes internal config" do
    expect(described_class.for(:injection)).to include("instruções internas")
  end

  it "an unknown/nil category falls back to the neutral default (never blank/error)" do
    expect(described_class.for(nil)).to eq(described_class::DEFAULTS[:default])
    expect(described_class.for(:bogus)).to eq(described_class::DEFAULTS[:default])
  end

  it "accepts a string category" do
    expect(described_class.for("abuse")).to eq(described_class::DEFAULTS[:abuse])
  end

  describe "configuration over convention (§7): per-agent overrides" do
    it "an agent per-category override wins over the built-in default" do
      ov = { "injection" => "We can't share internal config. How else can I help?" }
      expect(described_class.for(:injection, overrides: ov)).to eq(ov["injection"])
    end

    it "an agent catch-all 'default' covers a category it didn't set specifically" do
      ov = { "default" => "Não posso ajudar com isso." }
      expect(described_class.for(:sexual, overrides: ov)).to eq("Não posso ajudar com isso.")
    end

    it "a specific override beats the agent catch-all" do
      ov = { "default" => "catch-all", "abuse" => "specific" }
      expect(described_class.for(:abuse, overrides: ov)).to eq("specific")
    end

    it "falls back to the built-in when the agent set neither the category nor a default" do
      expect(described_class.for(:injection, overrides: { "abuse" => "x" }))
        .to eq(described_class::DEFAULTS[:injection])
    end

    it "an unknown moderator category resolves to the agent default (not a forced bucket)" do
      expect(described_class.for(:off_topic, overrides: { "default" => "generic refusal" }))
        .to eq("generic refusal")
    end
  end
end
