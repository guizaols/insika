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

    it "DEFAULT_LIMITS confere com D6 (+ approval_timeout da Fase 2)" do
      expect(described_class::DEFAULT_LIMITS).to eq(
        turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
        context_budget: 8_000, max_turns: 25, max_tool_calls: 50,
        approval_timeout: 3_600
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

  describe "capabilities (P2B, RFC-0004 §6) — assimetria opt-in" do
    it "default nil = NENHUMA capability (não 'todas', ao contrário de tools_allow)" do
      expect(described_class.build(id: "a", model: "m").capabilities).to be_nil
    end

    it "aceita a lista explícita de intenções" do
      profile = described_class.build(id: "a", model: "m", capabilities: [:browse, :search])
      expect(profile.capabilities).to eq([:browse, :search])
    end

    it "perfil da Fase 1 (sem o kwarg) continua construível" do
      expect { described_class.build(id: "a", model: "m") }.not_to raise_error
    end
  end

  describe "tools_deferred (P2B, Tool Search)" do
    it "default nil = nenhuma deferred (tudo eager — paridade Fase 1)" do
      expect(described_class.build(id: "a", model: "m").tools_deferred).to be_nil
    end

    it "aceita a allowlist de tools searchable-not-wired" do
      profile = described_class.build(id: "a", model: "m", tools_deferred: %w[send_email create_invoice])
      expect(profile.tools_deferred).to eq(%w[send_email create_invoice])
    end
  end

  describe "memory (P2C, memória cross-session) — opt-in" do
    it "default nil = OFF (paridade Fase 1)" do
      expect(described_class.build(id: "a", model: "m").memory).to be_nil
    end

    it "aceita memory: true (ligado)" do
      expect(described_class.build(id: "a", model: "m", memory: true).memory).to be(true)
    end
  end

  describe "metadata + store_id (Fase 6, contexto de turno)" do
    it "default = {} (agente sem metadata)" do
      profile = described_class.build(id: "a", model: "m")
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end

    it "store_id lê do metadata (chave symbol)" do
      profile = described_class.build(id: "a", model: "m", metadata: { store_id: "loja-7" })
      expect(profile.store_id).to eq("loja-7")
    end

    it "store_id tolera chave string (JSON round-trip do store)" do
      profile = described_class.build(id: "a", model: "m", metadata: { "store_id" => "loja-9" })
      expect(profile.store_id).to eq("loja-9")
    end

    it "metadata: nil vira {} (não quebra store_id)" do
      profile = described_class.build(id: "a", model: "m", metadata: nil)
      expect(profile.metadata).to eq({})
      expect(profile.store_id).to be_nil
    end
  end
end
