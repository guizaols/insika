# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Native approval resolver with Insika's durable store" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:pending) { Insika::PendingActionStore.new(store: backend) }
  let(:writes) { [] }
  let(:context) do
    RubyLLM.context { |config| config.deepseek_api_key = "spec-only" }
  end

  def new_chat
    context.chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true)
  end

  def writer(store = pending)
    sink = writes
    Class.new(RubyLLM::Tool) do
      requires_approval do |call|
        status = store.find("t:1:#{call.id}")&.status
        { approved: true, rejected: false }[status]
      end
      define_method(:name) { "write" }
      define_method(:execute) { sink << "written"; "written" }
    end.new
  end

  def prepare_chat(*tools)
    new_chat.with_tools(*tools).tap do |chat|
      calls = tools.each_with_index.to_h do |tool, index|
        id = "call-#{index}"
        [id, RubyLLM::ToolCall.new(id: id, name: tool.name, arguments: {})]
      end
      chat.add_message(role: :assistant, content: "", tool_calls: calls)
    end
  end

  it "runs an ungated sibling while the persisted operator action remains pending" do
    reads = []
    reader = Class.new(RubyLLM::Tool) do
      define_method(:name) { "read" }
      define_method(:execute) { reads << "read"; "read" }
    end.new
    pending.create(id: "t:1:call-0", task_id: "t", turn: 1, tool: "write")
    chat = prepare_chat(writer, reader)

    chat.run_tools

    expect(reads).to eq(["read"])
    expect(writes).to be_empty
    expect(chat.awaiting_approval?).to be(true)
    expect(chat.pending_approvals.map(&:id)).to eq(["call-0"])
    expect(pending.find("t:1:call-0").status).to eq(:pending)
  end

  %i[approved rejected].each do |decision|
    it "reloads a #{decision} decision through the resolver without another operator action" do
      pending.create(id: "t:1:call-0", task_id: "t", turn: 1, tool: "write")
      original = prepare_chat(writer)
      transcript = JSON.parse(JSON.generate(original.messages.map(&:to_h)))
      pending.resolve("t:1:call-0", decision: decision, operator: "operator-1")
      restored_store = Insika::PendingActionStore.new(store: backend)
      restored = new_chat.with_tools(writer(restored_store))
      transcript.each { |message| restored.add_message(message.transform_keys(&:to_sym)) }

      restored.run_tools

      expect(writes).to eq(decision == :approved ? ["written"] : [])
      expect(restored.messages.last.tool_call_id).to eq("call-0")
      expect(restored.messages.last.content).to include(decision == :approved ? "written" : "denied")
      expect(restored.pending_approvals).to be_empty
      expect(restored_store.find("t:1:call-0").resolved_by).to eq("operator-1")
    end
  end

  it "does not let an in-memory approval bypass an unresolved durable decision" do
    pending.create(id: "t:1:call-0", task_id: "t", turn: 1, tool: "write")
    chat = prepare_chat(writer)
    chat.approve("call-0")

    chat.run_tools

    expect(writes).to be_empty
    expect(chat.awaiting_approval?).to be(true)
    expect(pending.find("t:1:call-0").status).to eq(:pending)
  end
end
