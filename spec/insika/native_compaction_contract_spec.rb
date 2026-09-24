# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Native compaction persistence boundaries" do
  let(:context) { RubyLLM.context { |config| config.openai_api_key = "spec-only" } }
  let(:chat) { context.chat(model: "gpt-4o-mini", provider: :openai) }
  let(:protocol) { RubyLLM::Providers::OpenAI::Responses.new(chat.provider, chat.model) }
  let(:opaque) do
    { "object" => "response.compaction",
      "output" => [{ "type" => "compaction", "encrypted_content" => "provider-bound-state" }] }
  end

  def reload_message(message)
    RubyLLM::Message.new(**JSON.parse(JSON.generate(message.to_h)).transform_keys(&:to_sym))
  end

  it "round-trips manual compaction and replaces only the wire prefix" do
    chat.add_message(role: :user, content: "earlier history")
    compacted = protocol.parse_compaction_response(Struct.new(:body).new(opaque))
    expect(chat.provider).to receive(:compact).and_return(compacted)

    expect(chat.compact).to equal(compacted)
    expect(chat.messages.map(&:content)).to eq(["earlier history", ""])
    chat.messages = chat.messages.map { |message| reload_message(message) }
    chat.add_message(role: :user, content: "next question")

    wire = protocol.render_compaction_payload(chat.messages).fetch(:input)
    expect(wire.first).to eq(opaque.fetch("output").first)
    expect(JSON.generate(wire)).to include("next question")
    expect(JSON.generate(wire)).not_to include("earlier history")
    expect(chat.messages.first.content).to eq("earlier history")
  end

  it "does not automatically remove provider-bound state when the model changes" do
    chat.add_message(role: :assistant, content: "", raw_content: opaque)
    chat.with_model("gpt-4o", provider: :openai)

    expect(chat.messages.last.raw_content).to eq(opaque)
  end

  it "rejects manual compaction while a tool result is missing" do
    chat.add_message(role: :assistant, content: "", tool_calls: {
      "call-1" => RubyLLM::ToolCall.new(id: "call-1", name: "write", arguments: {})
    })
    expect(chat.provider).not_to receive(:compact)

    expect { chat.compact }.to raise_error(RubyLLM::PendingToolCallsError)
  end

  it "shows why removing top-level thinking does not sanitize raw Responses content" do
    raw = [{ "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "private reasoning" }] },
      { "type" => "message", "role" => "assistant",
        "content" => [{ "type" => "output_text", "text" => "unredacted answer" }] }]
    message = RubyLLM::Message.new(role: :assistant, content: "[REDACTED]",
      thinking: "private reasoning", raw_content: raw).without_thinking

    restored = reload_message(message)
    expect(restored.thinking).to be_nil
    expect(protocol.render_compaction_payload([restored]).fetch(:input)).to eq(raw)
    serialized = Insika::Executor.allocate.send(:serialize_chat_message, restored)
    expect(serialized).to eq("role" => "assistant", "content" => "[REDACTED]")
  end

  it "keeps raw tool output from bypassing the persisted content limit" do
    text = "x" * (Insika::Executor::TOOL_CONTENT_CAP + 100)
    message = RubyLLM::Message.new(role: :tool, content: text, tool_call_id: "call-1",
      raw_content: [{ "type" => "function_call_output", "call_id" => "call-1", "output" => text }])
    serialized = Insika::Executor.allocate.send(:serialize_chat_message, message)

    expect(serialized).not_to have_key("raw_content")
    expect(serialized.fetch("content")).to include("truncated")
    expect(serialized.fetch("content")).not_to eq(text)
    expect(serialized.fetch("tool_call_id")).to eq("call-1")
  end
end
