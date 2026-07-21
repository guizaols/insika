# frozen_string_literal: true

require "spec_helper"

# Characterization of TurnState (FOLLOWUP §11 R0). It is MUTABLE on purpose (the
# only exception to the Data types): the Middleware and the tool decorators write
# into it. This spec pins the initializer contract, the defaults, and the mutable
# fields R1 (tool-call baseline) and R4 (per-call correlation) will lean on.
RSpec.describe Harness::TurnState do
  def build(**overrides)
    defaults = {
      task: Struct.new(:id, :session_id).new("t", nil),
      profile: Harness::AgentProfile.build(id: "a", model: "m"),
      turn: 1,
      message: "olá"
    }
    described_class.new(**defaults.merge(overrides))
  end

  describe "#initialize" do
    it "expõe a identidade do turno (task/profile/turn/message)" do
      task = Struct.new(:id, :session_id).new("task-1", "sess-1")
      profile = Harness::AgentProfile.build(id: "agente", model: "m")
      state = described_class.new(task: task, profile: profile, turn: 3, message: "oi")

      expect(state.task).to be(task)
      expect(state.profile).to be(profile)
      expect(state.turn).to eq(3)
      expect(state.message).to eq("oi")
    end

    it "capability_names começa em {} (não nil — evita NoMethodError na junção pós-Policy)" do
      expect(build.capability_names).to eq({})
    end

    it "task/profile/turn são read-only (identidade); message é rewritável pela Middleware" do
      state = build
      expect(state).not_to respond_to(:task=)
      expect(state).not_to respond_to(:turn=)

      state.message = "reescrito"
      expect(state.message).to eq("reescrito")
    end
  end

  describe "campos mutáveis do runtime (round-trip)" do
    # Cada campo que R1/R4/Middleware escrevem: garante que segue read/write.
    %i[
      context allowed_tools allowed_skills chat session model_selection
      halt_reason halt_response guardrail_block guardrail_flags response_content
      output_filter current_tool_call capability_names tenant turn_context usage
      skip_side_effects requires_approval approval_coordinator actor
    ].each do |field|
      it "#{field} é acessível para leitura e escrita" do
        state = build
        sentinel = Object.new
        state.public_send("#{field}=", sentinel)
        expect(state.public_send(field)).to be(sentinel)
      end
    end

    it "current_tool_call default é nil (correlação — slot único preenchido no before_tool_call)" do
      expect(build.current_tool_call).to be_nil
    end

    it "skip_side_effects default é nil (Array(nil) => [] no envelope; turno novo)" do
      expect(build.skip_side_effects).to be_nil
    end
  end
end
