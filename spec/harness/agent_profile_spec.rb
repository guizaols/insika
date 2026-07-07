# frozen_string_literal: true

RSpec.describe Harness::AgentProfile do
  describe "compatibilidade com a Fase 0" do
    it "aceita a assinatura mínima da Fase 0" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.id).to eq("a")
      expect(profile.model).to eq("m")
      expect(profile.provider).to be_nil
      expect(profile.base_prompt).to eq("")
      expect(profile.prompt_files).to eq([])
      expect(profile.tools_allow).to be_nil
      expect(profile.tools_deny).to eq([])
      expect(profile.skills).to be_nil
    end

    describe "#tool_opted_in? (preservado)" do
      it "true quando o nome está na allow" do
        profile = described_class.build(id: "a", model: "m", tools_allow: ["a"])
        expect(profile.tool_opted_in?("a")).to be(true)
        expect(profile.tool_opted_in?("b")).to be(false)
      end

      it "false com tools_allow nil" do
        profile = described_class.build(id: "a", model: "m")
        expect(profile.tool_opted_in?("a")).to be(false)
      end
    end
  end

  describe "campos novos (D6)" do
    let(:profile) { described_class.build(id: "a", model: "m") }

    it "tem defaults corretos" do
      expect(profile.context_providers).to be_nil
      expect(profile.workflows_allow).to be_nil
      expect(profile.policies).to eq([])
      expect(profile.prompt_refs).to eq([])
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS)
    end

    it "DEFAULT_LIMITS confere com D6" do
      expect(described_class::DEFAULT_LIMITS).to eq(
        turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
        context_budget: 8_000, max_turns: 25, max_tool_calls: 50
      )
    end

    it "limits faz merge parcial, não substituição" do
      # valor distinto de qualquer default para o override não coincidir com
      # uma chave preservada (tool_timeout também é 60 por default).
      profile = described_class.build(id: "a", model: "m", limits: { turn_timeout: 999 })
      expect(profile.limits).to eq(described_class::DEFAULT_LIMITS.merge(turn_timeout: 999))
    end
  end

  describe "normalização Array()" do
    it "aceita valor único em tools_deny, policies e prompt_refs" do
      profile = described_class.build(
        id: "a", model: "m", tools_deny: "x", policies: "p", prompt_refs: "r"
      )
      expect(profile.tools_deny).to eq(["x"])
      expect(profile.policies).to eq(["p"])
      expect(profile.prompt_refs).to eq(["r"])
    end
  end
end
