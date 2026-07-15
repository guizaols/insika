# frozen_string_literal: true

require "spec_helper"

# Fase 6, Etapa B (tasks 3-4): o Executor aterrissa o CONTEXTO DE TURNO
# (chat_id/agent_id/tenant/store_id) no TurnState e o DEPOSITA nas instâncias de
# data-tool (via `turn_context=`), ANTES do ToolEnvelope — a costura que permite
# {{ctx.*}} emitir X-Chat-Id/X-Store-Id/X-Agent-Id ao /api/internal/*.
RSpec.describe "Harness::Executor — contexto de turno (P6 Etapa B)" do
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

  def task_with(session_id:)
    Struct.new(:id, :session_id, :command).new(
      "t", session_id, { "type" => "send_message", "payload" => { "message" => "oi" }, "meta" => {} }
    )
  end

  describe "#build_turn_context" do
    let(:profile) { Harness::AgentProfile.build(id: "bia", model: "m", metadata: { store_id: "loja-7" }) }

    def state_with(tenant:)
      s = Harness::TurnState.new(task: nil, profile: profile, turn: 1, message: "oi")
      s.tenant = tenant
      s
    end

    it "chat_id=sessão, agent_id=profile, store_id=metadata, tenant=chat_id (drop-in)" do
      ctx = executor.send(:build_turn_context, task_with(session_id: "chat-42"), profile, state_with(tenant: nil))
      expect(ctx).to eq(chat_id: "chat-42", agent_id: "bia", tenant: "chat-42", store_id: "loja-7")
    end

    it "tenant explícito do Command (memória) prevalece sobre chat_id" do
      ctx = executor.send(:build_turn_context, task_with(session_id: "chat-42"), profile, state_with(tenant: "acme"))
      expect(ctx[:tenant]).to eq("acme")
      expect(ctx[:chat_id]).to eq("chat-42")
    end

    it "sem store_id no profile -> store_id nil (header sairá vazio)" do
      bare = Harness::AgentProfile.build(id: "a", model: "m")
      ctx = executor.send(:build_turn_context, task_with(session_id: "c1"), bare, state_with(tenant: nil))
      expect(ctx[:store_id]).to be_nil
    end
  end

  describe "#assemble_tool_instances — injeção do contexto de turno" do
    # tool fake que expõe turn_context= (como o DataDefinedTool).
    def ctx_tool(name)
      Class.new do
        attr_accessor :turn_context
        define_method(:name) { name }
      end.new
    end

    # Entry duck-typed (só factory/name — como Registry::Entry).
    def entry(tool)
      Struct.new(:name, :factory).new(tool.name, -> { tool })
    end

    it "deposita o turn_context na instância de data-tool antes do envelope" do
      tool = ctx_tool("cart")
      state = Harness::TurnState.new(task: nil, profile: nil, turn: 1, message: "x")
      state.turn_context = { chat_id: "c1", store_id: "s1", agent_id: "a1", tenant: "c1" }

      out = executor.send(:assemble_tool_instances, [entry(tool)], state)

      expect(out).to eq([tool])
      expect(tool.turn_context).to eq({ chat_id: "c1", store_id: "s1", agent_id: "a1", tenant: "c1" })
    end

    it "tool sem turn_context= é ignorada (paridade — não levanta)" do
      plain = Struct.new(:name).new("plain")
      state = Harness::TurnState.new(task: nil, profile: nil, turn: 1, message: "x")
      state.turn_context = { chat_id: "c1" }
      out = executor.send(:assemble_tool_instances, [Struct.new(:name, :factory).new("plain", -> { plain })], state)
      expect(out).to eq([plain])
    end

    it "state sem turn_context (stub) -> no-op, sem injeção" do
      tool = ctx_tool("cart")
      stub_state = Struct.new(:capability_names).new({}) # não responde a turn_context
      out = executor.send(:assemble_tool_instances, [entry(tool)], stub_state)
      expect(out).to eq([tool])
      expect(tool.turn_context).to be_nil
    end
  end
end
