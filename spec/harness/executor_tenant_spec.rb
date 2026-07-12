# frozen_string_literal: true

require "spec_helper"

# Threading de tenant (P2C task 3, D6): o Executor::ContextRequest (Struct que os
# providers REALMENTE recebem) passa a carregar o tenant, extraído do Command.
RSpec.describe "Harness::Executor — threading de tenant (P2C)" do
  let(:inert) { Object.new }
  let(:session_store) { Class.new { def find(_id) = nil }.new }

  subject(:executor) do
    Harness::Executor.new(
      context_builder: inert, policy_engine: inert, middleware: inert,
      hooks: Harness::Hooks.new, tool_registry: inert, skill_catalog: inert, profiles: {},
      session_store: session_store, task_store: inert, checkpoint_store: inert,
      event_stream: inert
    )
  end

  def task_with(meta:)
    Struct.new(:id, :session_id, :command).new(
      "t", nil, { "type" => "send_message", "payload" => { "message" => "oi" }, "meta" => meta }
    )
  end

  describe "#command_tenant" do
    it "extrai o tenant do meta do Command (chave string)" do
      expect(executor.send(:command_tenant, task_with(meta: { "tenant" => "acme" }))).to eq("acme")
    end

    it "extrai o tenant do meta (chave symbol)" do
      expect(executor.send(:command_tenant, task_with(meta: { tenant: "acme" }))).to eq("acme")
    end

    it "sem tenant -> nil (MemoryStore aplica _default)" do
      expect(executor.send(:command_tenant, task_with(meta: {}))).to be_nil
    end
  end

  describe "#build_context_request" do
    it "o ContextRequest (Struct) carrega o tenant" do
      profile = Harness::AgentProfile.build(id: "a", model: "m")
      state = Harness::TurnState.new(task: nil, profile: profile, turn: 1, message: "oi")
      task = task_with(meta: { "tenant" => "acme" })
      req = executor.send(:build_context_request, task, profile, state, nil)
      expect(req.tenant).to eq("acme")
      expect(req.respond_to?(:tenant)).to be(true) # o seam da Fase 1 reconciliado
    end
  end
end
