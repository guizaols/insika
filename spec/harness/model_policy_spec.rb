# frozen_string_literal: true

require "spec_helper"

# LLM config v2 (§10): the per-agent model fence.
RSpec.describe Harness::ModelPolicy do
  describe ".allowed?" do
    it "nil policy = NO fence (every model allowed — parity)" do
      expect(described_class.allowed?(nil, model: "anything", provider: :deepseek)).to be(true)
    end

    it "nil/absent allow list = no fence" do
      expect(described_class.allowed?({ "other" => 1 }, model: "x", provider: :y)).to be(true)
      expect(described_class.allowed?({ "allow" => nil }, model: "x", provider: :y)).to be(true)
    end

    it "empty allow = deny-all" do
      expect(described_class.allowed?({ "allow" => [] }, model: "x", provider: :y)).to be(false)
    end

    it "exact provider/model ref" do
      policy = { "allow" => ["deepseek/deepseek-chat"] }
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: :deepseek)).to be(true)
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: :openai)).to be(false)
      expect(described_class.allowed?(policy, model: "deepseek-reasoner", provider: :deepseek)).to be(false)
    end

    it "provider wildcard provider/*" do
      policy = { "allow" => ["deepseek/*"] }
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: :deepseek)).to be(true)
      expect(described_class.allowed?(policy, model: "deepseek-reasoner", provider: :deepseek)).to be(true)
      expect(described_class.allowed?(policy, model: "gpt-4o", provider: :openai)).to be(false)
    end

    it "bare model ref matches under ANY provider (provider-agnostic)" do
      policy = { "allow" => ["deepseek-chat"] }
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: :deepseek)).to be(true)
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: nil)).to be(true)
      expect(described_class.allowed?(policy, model: "gpt-4o", provider: :openai)).to be(false)
    end

    it "matches if ANY ref in the list matches" do
      policy = { "allow" => ["openai/*", "deepseek/deepseek-chat"] }
      expect(described_class.allowed?(policy, model: "deepseek-chat", provider: :deepseek)).to be(true)
      expect(described_class.allowed?(policy, model: "gpt-4o", provider: :openai)).to be(true)
      expect(described_class.allowed?(policy, model: "claude-x", provider: :anthropic)).to be(false)
    end

    it "tolerates a symbol allow key" do
      expect(described_class.allowed?({ allow: ["deepseek/*"] }, model: "m", provider: :deepseek)).to be(true)
    end
  end
end
