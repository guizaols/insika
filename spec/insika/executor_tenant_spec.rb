# frozen_string_literal: true

require "spec_helper"

# Tenant threading (P2C task 3, D6): the Executor::ContextRequest (the Struct the
# providers ACTUALLY receive) now carries the tenant, extracted from the Command.
RSpec.describe "Insika::Executor — tenant threading (P2C)" do
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

  def task_with(meta:)
    Struct.new(:id, :session_id, :command).new(
      "t", nil, { "type" => "send_message", "payload" => { "message" => "oi" }, "meta" => meta }
    )
  end

  describe "#command_tenant" do
    it "extracts the tenant from the Command's meta (string key)" do
      expect(executor.send(:command_tenant, task_with(meta: { "tenant" => "acme" }))).to eq("acme")
    end

    it "extracts the tenant from meta (symbol key)" do
      expect(executor.send(:command_tenant, task_with(meta: { tenant: "acme" }))).to eq("acme")
    end

    it "no tenant -> nil (MemoryStore applies _default)" do
      expect(executor.send(:command_tenant, task_with(meta: {}))).to be_nil
    end
  end

  describe "#build_context_request" do
    it "the ContextRequest (Struct) carries the tenant" do
      profile = Insika::AgentProfile.build(id: "a", model: "m")
      state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "oi")
      task = task_with(meta: { "tenant" => "acme" })
      req = executor.send(:build_context_request, task, profile, state, nil)
      expect(req.tenant).to eq("acme")
      expect(req.respond_to?(:tenant)).to be(true) # the Phase 1 seam reconciled
    end
  end

  # :vars seam reconciled (bug found by actually running): the Request/Session
  # provider call request.vars; without it, they broke at runtime (undefined
  # method 'vars') and the session history was never injected.
  describe "#build_context_request — :vars" do
    let(:session) { Struct.new(:id, :vars).new("s1", { "cliente" => "Ana" }) }

    it "loads vars with the session's vars + the Command's explicit history" do
      store = Struct.new(:session) do
        def find(_id) = session
      end.new(session)
      exec = Insika::Executor.new(
        context_builder: inert, policy_engine: inert, middleware: inert, hooks: Insika::Hooks.new,
        tool_registry: inert, skill_catalog: inert, profiles: {}, session_store: store,
        task_store: inert, checkpoint_store: inert, event_stream: inert
      )
      profile = Insika::AgentProfile.build(id: "a", model: "m")
      state = Insika::TurnState.new(task: nil, profile: profile, turn: 1, message: "oi")
      task = Struct.new(:id, :session_id, :command).new(
        "t", "s1", { "type" => "send_message", "payload" => { "history" => [{ "role" => "user" }] }, "meta" => {} }
      )
      req = exec.send(:build_context_request, task, profile, state, nil)
      expect(req.respond_to?(:vars)).to be(true)
      expect(req.vars["cliente"]).to eq("Ana")          # session vars (Request provider)
      expect(req.vars["history"]).to eq([{ "role" => "user" }]) # Session provider convention
    end
  end
end
