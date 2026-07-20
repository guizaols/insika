# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Safety::OutputValidator do
  def state(content, guardrails: nil)
    prof = Harness::AgentProfile.build(id: "example-agent", guardrails: guardrails)
    st = Harness::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
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
      st = state("resposta qualquer", guardrails: { "moderator" => "on" })
      v = described_class.new(ask_factory: ->(_c) { ->(_p) { raise "down" } })
      expect { v.call(st) }.not_to raise_error
      expect(st.guardrail_flags).to be_nil
    end
  end
end
