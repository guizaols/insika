# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../server/a2a/app"

RSpec.describe Harness::Server::A2A::App do
  let(:backend) { Harness::Stores::Memory.new }
  let(:session_store) { Harness::SessionStore.new(store: backend) }
  let(:task_store) { Harness::TaskStore.new(store: backend) }
  let(:skill_catalog) { Harness::SkillCatalog.new([]) }
  let(:profiles) { { "assistant" => Harness::AgentProfile.build(id: "assistant", model: "m", base_prompt: "SOUL") } }

  # FAKE bus (unit): reproduces the minimum of the handlers deterministically. The
  # integration with the REAL handlers/Executor is the E2E smoke (task 8).
  let(:command_bus) do
    Class.new do
      attr_reader :dispatched

      def initialize(task_store, session_store) = (@task_store = task_store; @session_store = session_store; @dispatched = [])

      def dispatch(command)
        @dispatched << command
        case command.type
        when :create_session then @session_store.create(vars: {})
        when :send_message
          task = @task_store.create(command: command, session_id: command.payload[:session_id])
          { task_id: task.id }
        when :cancel_task
          @task_store.transition(command.payload[:task_id], to: :cancelled)
          @task_store.find(command.payload[:task_id])
        end
      end
    end.new(task_store, session_store)
  end

  subject(:app) do
    described_class.new(command_bus: command_bus, task_store: task_store, session_store: session_store,
                        profiles: profiles, skill_catalog: skill_catalog,
                        config: { a2a_agent: "assistant", base_url: "https://h.example" })
  end

  def rpc(method, params = {}, id: "1")
    app.rpc({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  describe "message/send" do
    it "creates a session (contextId missing), dispatches send_message and returns an A2A Task" do
      res = rpc("message/send", { "message" => { "parts" => [{ "kind" => "text", "text" => "oi" }] } })
      types = command_bus.dispatched.map(&:type)
      expect(types).to eq(%i[create_session send_message])

      sent = command_bus.dispatched.last
      expect(sent.payload).to include(agent: "assistant", message: "oi")
      expect(sent.meta[:transport]).to eq(:a2a)

      task = res[:result]
      expect(task[:kind]).to eq("task")
      expect(task[:status][:state]).to eq("submitted")
      expect(task[:contextId]).to eq(sent.payload[:session_id])
    end

    it "uses the message's contextId when present (without creating a session)" do
      session = session_store.create(vars: {})
      rpc("message/send", { "message" => { "contextId" => session.id, "parts" => [{ "kind" => "text", "text" => "oi" }] } })
      expect(command_bus.dispatched.map(&:type)).to eq(%i[send_message])
    end
  end

  describe "tasks/get" do
    it "projects the current state" do
      task = task_store.create(command: { "type" => "send_message" }, session_id: "s1")
      res = rpc("tasks/get", { "id" => task.id })
      expect(res[:result][:status][:state]).to eq("submitted")
    end

    it "task completed -> status.message with the transcript content" do
      task = task_store.create(command: { "type" => "send_message" }, session_id: "s1")
      session_store.create(id: "s1", vars: {})
      session_store.append_messages("s1", [{ "role" => "user", "content" => "oi" },
                                           { "role" => "assistant", "content" => "olá!" }])
      task_store.begin_execution(task.id)
      task_store.transition(task.id, to: :running)
      task_store.finish_execution(task.id, outcome: :completed)
      task_store.transition(task.id, to: :completed)

      res = rpc("tasks/get", { "id" => task.id })
      expect(res[:result][:status][:state]).to eq("completed")
      expect(res[:result][:status][:message][:parts].first[:text]).to eq("olá!")
    end

    it "nonexistent task -> -32001" do
      expect(rpc("tasks/get", { "id" => "nope" })[:error][:code]).to eq(Harness::Server::A2A::Errors::TASK_NOT_FOUND)
    end
  end

  describe "tasks/cancel" do
    it "dispatches cancel_task and projects 'canceled'" do
      task = task_store.create(command: { "type" => "send_message" }, session_id: "s1")
      res = rpc("tasks/cancel", { "id" => task.id })
      expect(command_bus.dispatched.map(&:type)).to eq(%i[cancel_task])
      expect(res[:result][:status][:state]).to eq("canceled")
    end
  end

  describe "errors" do
    it "unknown method -> -32601" do
      expect(rpc("foo/bar")[:error][:code]).to eq(Harness::Server::A2A::Errors::METHOD_NOT_FOUND)
    end

    it "invalid request (no jsonrpc) -> -32600" do
      expect(app.rpc({ "id" => "1", "method" => "tasks/get" })[:error][:code]).to eq(-32_600)
    end

    it "never leaks an exception -> -32603" do
      allow(command_bus).to receive(:dispatch).and_raise(RuntimeError.new("boom interno"))
      res = rpc("message/send", { "message" => { "parts" => [{ "kind" => "text", "text" => "x" }] } })
      expect(res[:error][:code]).to eq(Harness::Server::A2A::Errors::INTERNAL_ERROR)
      expect(res[:error][:message]).to eq("internal error")
    end
  end

  describe "#agent_card" do
    it "builds the card for the configured agent" do
      card = app.agent_card
      expect(card[:name]).to eq("assistant")
      expect(card[:url]).to eq("https://h.example/a2a")
      expect(card[:capabilities][:streaming]).to be(false)
    end
  end

  # §9.6: A2A::App already does ProfileSource.coerce — passing a StoredProfileSource
  # (the deployment's dynamic source) makes the AgentCard/inbound see agents
  # created in Studio, without a static PROFILES.
  describe "profiles via StoredProfileSource (§9.6)" do
    it "resolves the agent_card of an agent created in the store (Studio)" do
      cs = Harness::ConfigStore.new(store: Harness::Stores::Memory.new)
      src = Harness::StoredProfileSource.new(config_store: cs)
      src.put(Harness::AgentProfile.build(id: "bia", model: "m", base_prompt: "SOUL da Bia"))

      stored_app = described_class.new(
        command_bus: command_bus, task_store: task_store, session_store: session_store,
        profiles: src, skill_catalog: skill_catalog,
        config: { a2a_agent: "bia", base_url: "https://h.example" }
      )
      card = stored_app.agent_card
      expect(card[:name]).to eq("bia")
      expect(card[:description]).to include("SOUL da Bia")
    end
  end
end
