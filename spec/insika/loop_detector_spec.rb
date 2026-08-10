# frozen_string_literal: true

require "spec_helper"

# RFC-0020 — the detector is driven directly with the gem's message shapes
# (FakeChat::Message mirrors them), so the batch-boundary arithmetic is exercised
# without a provider. The ChatBuilder wiring around it lives in
# chat_builder_spec; the full-turn death in executor_hooks_spec.
RSpec.describe Insika::LoopDetector do
  let(:chat) { FakeChat.new }
  let(:sink) { [] }
  let(:emit) { ->(type, data) { sink << { type: type, data: data } } }

  def detector(limit: 3) = described_class.new(chat: chat, limit: limit, emit: emit)

  def assistant_with_calls(n)
    calls = (1..n).to_h { |i| ["call_#{i}", FakeChat::ToolCall.new("t#{i}", {}, "call_#{i}")] }
    FakeChat::Message.new("assistant", nil, calls)
  end

  def tool_message = FakeChat::Message.new("tool", "result", nil)

  # One full cycle the way RubyLLM orders it: the assistant message announcing
  # the call, the before-hook, the raw result, the role:tool message closing.
  def call_cycle(det, name, arguments)
    det.message_ended(assistant_with_calls(1))
    det.tool_call(name, arguments)
    det.tool_result("result")
    det.message_ended(tool_message)
  end

  def interventions = chat.messages.select { |m| m[:role] == :user }

  it "warns ONCE at the batch boundary when the streak reaches the limit" do
    det = detector(limit: 3)
    2.times { call_cycle(det, "lookup", { "q" => "vestido" }) }
    expect(interventions).to be_empty # 2 < 3: nothing yet

    call_cycle(det, "lookup", { "q" => "vestido" })

    expect(interventions.size).to eq(1)
    expect(interventions.first[:content]).to include("lookup", "3 times")
    event = sink.find { |e| e[:type] == :tool_loop_intervened }
    expect(event[:data]).to eq({ name: "lookup", streak: 3 })
  end

  it "never puts the arguments in the message or the event (order numbers are PII)" do
    det = detector(limit: 2)
    2.times { call_cycle(det, "get_order", { "order" => "1234567" }) }

    expect(interventions.first[:content]).not_to include("1234567")
    expect(sink.flat_map { |e| e[:data].values }.join).not_to include("1234567")
  end

  it "treats key order and string/symbol keys as the SAME call" do
    det = detector(limit: 2)
    call_cycle(det, :lookup, { q: "x", page: 1 })
    call_cycle(det, "lookup", { "page" => 1, "q" => "x" })

    expect(interventions.size).to eq(1)
  end

  it "resets the streak when a DIFFERENT call intervenes" do
    det = detector(limit: 2)
    call_cycle(det, "lookup", { "q" => "x" })
    call_cycle(det, "lookup", { "q" => "y" }) # different args: streak restarts
    call_cycle(det, "other", {})

    expect(interventions).to be_empty
  end

  it "appends only at the LAST tool result of a batch, never mid-batch" do
    det = detector(limit: 2)
    # A batch of TWO identical calls: the streak fires on the second before-hook,
    # but the first result closing must NOT deliver the message.
    det.message_ended(assistant_with_calls(2))
    det.tool_call("lookup", { "q" => "x" })
    det.tool_call("lookup", { "q" => "x" })
    det.tool_result("r1")
    det.message_ended(tool_message)
    expect(interventions).to be_empty

    det.tool_result("r2")
    det.message_ended(tool_message)
    expect(interventions.size).to eq(1)
  end

  it "delivers nothing into a halted batch (halt_when has no next model step)" do
    require "ruby_llm"
    det = detector(limit: 2)
    det.message_ended(assistant_with_calls(2))
    det.tool_call("lookup", { "q" => "x" })
    det.tool_call("lookup", { "q" => "x" })
    det.tool_result(RubyLLM::Tool::Halt.new("payload"))
    det.message_ended(tool_message)
    det.tool_result("r2")
    det.message_ended(tool_message)

    expect(interventions).to be_empty
    expect(sink).to be_empty
  end

  it "aborts the repeat that arrives AFTER the warning, before the call executes" do
    det = detector(limit: 2)
    2.times { call_cycle(det, "lookup", { "q" => "x" }) }
    expect(interventions.size).to eq(1)

    det.message_ended(assistant_with_calls(1))
    expect { det.tool_call("lookup", { "q" => "x" }) }
      .to raise_error(Insika::TimeoutError) { |e|
        expect(e.stage).to eq(:tool_limit)
        expect(e.message).to include("lookup")
      }
  end

  it "spends the warning on the TURN: a fresh loop on another tool aborts unwarned" do
    det = detector(limit: 2)
    2.times { call_cycle(det, "lookup", { "q" => "x" }) }
    expect(interventions.size).to eq(1)

    call_cycle(det, "other", { "i" => 0 })   # a different call: streak restarts
    det.message_ended(assistant_with_calls(1))
    det.tool_call("other", { "i" => 1 })     # streak 1
    det.tool_result("r")
    det.message_ended(tool_message)
    det.message_ended(assistant_with_calls(1))
    expect { det.tool_call("other", { "i" => 1 }) } # streak 2, warning spent
      .to raise_error(Insika::TimeoutError) { |e| expect(e.stage).to eq(:tool_limit) }
    expect(interventions.size).to eq(1) # still ONE warning
  end

  it "drops a pending warning when the model stops calling tools (turn ending)" do
    det = detector(limit: 2)
    det.message_ended(assistant_with_calls(1))
    det.tool_call("lookup", { "q" => "x" })
    det.tool_result("r")
    det.message_ended(tool_message)
    det.message_ended(assistant_with_calls(1)) # announces another call…
    det.tool_call("lookup", { "q" => "x" })    # …the repeat that arms the warning
    det.message_ended(FakeChat::Message.new("assistant", "the answer", nil)) # but then answers

    expect(interventions).to be_empty
  end
end
