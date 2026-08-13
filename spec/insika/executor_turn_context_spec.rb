# frozen_string_literal: true

require "spec_helper"

# (tasks 3-4): the Executor lands the TURN CONTEXT
# (chat_id/agent_id/tenant/store_id) into the TurnState and DEPOSITS it into the
# data-tool instances (via `turn_context=`), BEFORE the ToolEnvelope — the seam that lets
# {{ctx.*}} emit X-Chat-Id/X-Store-Id/X-Agent-Id to /api/internal/*.
RSpec.describe "Insika::Executor — turn context" do
  let(:inert) { Object.new }
  let(:session_store) { Class.new { def find(_id) = nil }.new }

  subject(:executor) do
    Insika::Executor.new(
      context_builder: inert, policy_engine: inert, middleware: inert,
      hooks: Insika::Hooks.new, tool_registry: inert, skill_catalog: inert, profiles: {},
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
    let(:profile) { Insika::AgentProfile.build(id: "bia", model: "m", metadata: { store_id: "loja-7" }) }

    def state_with(tenant:)
      s = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "oi")
      s.tenant = tenant
      s
    end

    it "chat_id=session, agent_id=profile, store_id=metadata, tenant=state.tenant (=chat)" do
      # state.tenant was already set by run_pipeline via memory_tenant (=chat here).
      ctx = executor.send(:build_turn_context, task_with(session_id: "chat-42"), profile, state_with(tenant: "chat-42"))
      # delegation_depth: 0 for a top-level turn — set by run_subagent for children.
      expect(ctx).to eq(chat_id: "chat-42", agent_id: "bia", tenant: "chat-42",
                        store_id: "loja-7", delegation_depth: 0)
    end

    it "tenant reflects the multi-merchant override (the COMMAND tenant), not the chat" do
      # WS8: ctx.tenant is the data-tool header — the merchant, never the
      # customer. It is derived from the command tenant (or the chat when no
      # tenant), NOT from state.tenant: the memory scope may carry a customer
      # ("acme:123") and must never leak into the merchant's header.
      task = Struct.new(:id, :session_id, :command).new(
        "t", "chat-42",
        { "type" => "send_message", "payload" => { "message" => "oi" },
          "meta" => { "tenant" => "acme" } }
      )
      ctx = executor.send(:build_turn_context, task, profile, state_with(tenant: "acme:123"))
      expect(ctx[:tenant]).to eq("acme")
      expect(ctx[:chat_id]).to eq("chat-42")
    end

    it "no store_id in the profile -> store_id nil (header will be empty)" do
      bare = Insika::AgentProfile.build(id: "a", model: "m")
      ctx = executor.send(:build_turn_context, task_with(session_id: "c1"), bare, state_with(tenant: "c1"))
      expect(ctx[:store_id]).to be_nil
    end
  end

  # the engine's memory scope is PER-CHAT — command tenant wins, otherwise the
  # session. It's what the write path (state.tenant) and the read path (Memory provider)
  # use symmetrically.
  describe "#memory_tenant" do
    it "no tenant in the Command -> the session (=chat)" do
      expect(executor.send(:memory_tenant, task_with(session_id: "chat-42"))).to eq("chat-42")
    end

    it "the Command's explicit tenant prevails over the session" do
      task = Struct.new(:id, :session_id, :command).new(
        "t", "chat-42", { "type" => "send_message", "payload" => {}, "meta" => { "tenant" => "acme" } }
      )
      expect(executor.send(:memory_tenant, task)).to eq("acme")
    end

    it "one-shot (no session) and no tenant -> nil (MemoryStore applies _default)" do
      expect(executor.send(:memory_tenant, task_with(session_id: nil))).to be_nil
    end
  end

  describe "#assemble_tool_instances — turn context injection" do
    # fake tool that exposes turn_context= (like DataDefinedTool).
    def ctx_tool(name)
      Class.new do
        attr_accessor :turn_context
        define_method(:name) { name }
      end.new
    end

    # Duck-typed Entry (factory/name only — like Registry::Entry).
    def entry(tool)
      Struct.new(:name, :factory).new(tool.name, -> { tool })
    end

    it "deposits the turn_context into the data-tool instance before the envelope" do
      tool = ctx_tool("cart")
      state = Insika::TurnState.new(task: nil, profile: nil, turn: 1, message: "x")
      state.turn_context = { chat_id: "c1", store_id: "s1", agent_id: "a1", tenant: "c1" }

      out = executor.send(:assemble_tool_instances, [entry(tool)], state)

      expect(out).to eq([tool])
      expect(tool.turn_context).to eq({ chat_id: "c1", store_id: "s1", agent_id: "a1", tenant: "c1" })
    end

    it "tool without turn_context= is ignored (parity — does not raise)" do
      plain = Struct.new(:name).new("plain")
      state = Insika::TurnState.new(task: nil, profile: nil, turn: 1, message: "x")
      state.turn_context = { chat_id: "c1" }
      out = executor.send(:assemble_tool_instances, [Struct.new(:name, :factory).new("plain", -> { plain })], state)
      expect(out).to eq([plain])
    end

    it "state without turn_context (stub) -> no-op, no injection" do
      tool = ctx_tool("cart")
      stub_state = Struct.new(:capability_names).new({}) # does not respond to turn_context
      out = executor.send(:assemble_tool_instances, [entry(tool)], stub_state)
      expect(out).to eq([tool])
      expect(tool.turn_context).to be_nil
    end
  end
end
