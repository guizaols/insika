# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::OutputValidator do
  def state(content, guardrails: nil)
    prof = Insika::AgentProfile.build(id: "example-agent", guardrails: guardrails)
    st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
    st.response_content = content
    st
  end

  describe "deterministic tier (residual PII belt-and-suspenders)" do
    it "flags residual PII that reached the final text" do
      st = state("seu cpf é 123.456.789-01")
      described_class.new.call(st)
      expect(st.guardrail_flags.first).to include(category: "pii_residual", source: "deterministic")
      expect(st.guardrail_flags.first[:detail]).to include("cpf:1")
    end

    it "clean text yields no flags" do
      st = state("seu pedido chega amanhã")
      described_class.new.call(st)
      expect(st.guardrail_flags).to be_nil
    end

    it "respects output:false" do
      st = state("cpf 123.456.789-01", guardrails: { "output" => false })
      described_class.new.call(st)
      expect(st.guardrail_flags).to be_nil
    end

    it "empty content is a no-op" do
      st = state("")
      expect(described_class.new.call(st).guardrail_flags).to be_nil
    end
  end

  describe "LLM tier (opt-in)" do
    def ask_factory(reply)
      ->(_config) { ->(_prompt) { reply } }
    end

    it "flags an unverified discount promise" do
      st = state("Claro! Te dou 90% de desconto em tudo, pode confirmar.",
                 guardrails: { "moderator" => "on" })
      v = described_class.new(ask_factory: ask_factory('{"flagged":true,"category":"promise","reason":"invented discount"}'))
      v.call(st)
      flag = st.guardrail_flags.find { |f| f[:source] == "moderator" }
      expect(flag[:category]).to eq("promise")
    end

    it "does not flag an in-policy reply" do
      st = state("Nosso cupom atual é de 10%, quer que eu aplique?", guardrails: { "moderator" => "on" })
      v = described_class.new(ask_factory: ask_factory('{"flagged":false}'))
      v.call(st)
      expect(st.guardrail_flags).to be_nil
    end

    it "fails open when the LLM ask raises (audit must not break the turn)" do
      st = state("Claro! 90% de desconto!", guardrails: { "moderator" => "on" })
      v = described_class.new(ask_factory: ->(_) { raise "boom" })
      v.call(st)
      expect(st.guardrail_flags).to be_nil
    end
  end

  describe "grounding composition (D9 — runs BEFORE the output gate)" do
    def grounding_state(content, guardrails: { "output" => false })
      prof = Insika::AgentProfile.build(
        id: "grounded", guardrails: guardrails,
        grounding: { "mode" => "flag", "matcher" => { "sku" => '\b[A-Z]{2,4}\d{4,8}\b' } }
      )
      backend = Insika::Stores::Memory.new
      session_store = Insika::SessionStore.new(store: backend)
      session_store.create(id: "s1")
      ledger = Insika::EvidenceLedger.new(store: session_store, session_id: "s1")
      ledger.record(%w[TNSR1234])

      st = Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
      st.response_content = content
      st.evidence_ledger = ledger
      st
    end

    it "grounding flags even with guardrails output OFF (grounding is independent of the opt-in)" do
      st = grounding_state("O TNSR9999 está disponível.")
      described_class.new(grounding: Insika::Safety::GroundingValidator.new).call(st)

      expect(st.guardrail_flags.first).to include(category: "ungrounded", source: "evidence")
    end

    it "composes with the existing deterministic flags" do
      st = grounding_state("o cpf 123.456.789-01 e o TNSR9999 existem",
                           guardrails: { "output" => true })
      described_class.new(grounding: Insika::Safety::GroundingValidator.new).call(st)

      categories = st.guardrail_flags.map { |f| f[:category] }
      expect(categories).to include("ungrounded", "pii_residual")
    end
  end
end
