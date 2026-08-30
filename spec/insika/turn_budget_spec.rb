# frozen_string_literal: true

require "spec_helper"

# The budget is driven directly with the gem's message shapes (FakeChat::Message
# mirrors them), so the threshold arithmetic and the batch boundary are exercised
# without a provider. The ChatBuilder wiring lives in chat_builder_spec; the
# full-turn death in executor_hooks_spec.
RSpec.describe Insika::TurnBudget do
  let(:chat) { FakeChat.new }
  let(:sink) { [] }
  let(:emit) { ->(type, data) { sink << { type: type, data: data } } }

  def budget(max: 50) = described_class.new(chat: chat, max: max, emit: emit)

  def assistant_with_calls(n)
    calls = (1..n).to_h { |i| ["call_#{i}", FakeChat::ToolCall.new("t#{i}", {}, "call_#{i}")] }
    FakeChat::Message.new("assistant", nil, calls)
  end

  def tool_message = FakeChat::Message.new("tool", "result", nil)

  # One full cycle the way RubyLLM orders it.
  def call_cycle(b, result = "result")
    b.message_ended(assistant_with_calls(1))
    b.tool_call
    b.tool_result(result)
    b.message_ended(tool_message)
  end

  def notices = chat.messages.select { |m| m[:role] == :user }

  it "warns at 10, 5 and 2 calls remaining — once each, escalating" do
    b = budget(max: 50)
    38.times { call_cycle(b) }
    expect(notices).to be_empty

    call_cycle(b) # 39 made, 11 left
    expect(notices).to be_empty

    call_cycle(b) # 40 made, 10 left
    expect(notices.size).to eq(1)
    expect(notices.last[:content]).to include("10 of your 50 tool calls")

    5.times { call_cycle(b) } # 45 made, 5 left
    expect(notices.size).to eq(2)
    expect(notices.last[:content]).to include("5 tool calls left")

    3.times { call_cycle(b) } # 48 made, 2 left
    expect(notices.size).to eq(3)
    expect(notices.last[:content]).to include("2 tool calls left", "do not start new work")
  end

  it "emits :tool_budget_warned with the remaining count, never the tool arguments" do
    b = budget(max: 12)
    2.times { call_cycle(b) } # 10 left
    expect(sink).to eq([{ type: :tool_budget_warned, data: { remaining: 10, max: 12 } }])
  end

  it "still raises TimeoutError(stage: :tool_limit) past the ceiling" do
    b = budget(max: 2)
    2.times { call_cycle(b) }
    expect { b.tool_call }.to raise_error(Insika::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
  end

  it "max: nil is OFF — no count, no notice, no abort" do
    b = budget(max: nil)
    100.times { call_cycle(b) }
    expect(notices).to be_empty
    expect(sink).to be_empty
  end

  it "a limit smaller than a threshold simply never reaches it" do
    b = budget(max: 3)
    call_cycle(b) # 2 left -> the most urgent notice, and only that one
    expect(notices.size).to eq(1)
    expect(notices.first[:content]).to include("2 tool calls left")
  end

  it "a batch that crosses two thresholds delivers only the most urgent" do
    b = budget(max: 12)
    b.message_ended(assistant_with_calls(7))
    7.times { b.tool_call } # 12 -> 5 left, crossing 10 and 5
    6.times { b.message_ended(tool_message) }
    expect(notices).to be_empty # mid-batch: never between two tool results
    b.message_ended(tool_message)

    expect(notices.size).to eq(1)
    expect(notices.first[:content]).to include("5 tool calls left")
  end

  it "a halted batch (halt_when) receives nothing — nobody would read it" do
    skip "RubyLLM::Tool::Halt not loaded" unless defined?(RubyLLM::Tool::Halt)
    b = budget(max: 12)
    2.times { call_cycle(b, RubyLLM::Tool::Halt.new("done")) }
    expect(notices).to be_empty
  end

  it "the model stopping (an assistant message with no tool call) drops the armed notice" do
    b = budget(max: 12)
    b.message_ended(assistant_with_calls(1))
    b.tool_call # 10 left, armed
    b.message_ended(FakeChat::Message.new("assistant", "here is the answer", nil))

    expect(notices).to be_empty
  end
end
