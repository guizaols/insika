# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Executor native usage accounting" do
  let(:executor) { Insika::Executor.allocate }
  let(:state) do
    Insika::TurnState.new(task: nil, profile: Insika::AgentProfile.build(id: "a"),
                          turn: 1, message: "hello")
  end
  let(:chat) do
    RubyLLM.context { |config| config.openai_api_key = "spec-only" }
      .chat(model: "gpt-4o", provider: :openai)
  end

  def message(input:, output:, cached: nil, cost: nil, calls: nil)
    RubyLLM::Message.new(role: :assistant, content: calls ? nil : "done", model: "gpt-4o",
                        tokens: RubyLLM::Tokens.new(input: input, output: output, cache_read: cached),
                        cost: cost && RubyLLM::Cost.from_h({ total: cost }), tool_calls: calls)
  end

  it "accounts all generations in the native tool loop, not just its last response" do
    lookup = Class.new(RubyLLM::Tool) do
      def name = "lookup"
      def execute = "found"
    end.new
    chat.with_tools(lookup)
    call = RubyLLM::ToolCall.new(id: "one", name: "lookup", arguments: {})
    first = message(input: 10, output: 2, cached: 90, cost: 0.01, calls: { "one" => call })
    last = message(input: 20, output: 3, cached: 80, cost: 0.02)
    allow(chat.provider).to receive(:complete).and_return(first, last)
    chat.ask_later("hello")

    executor.send(:complete_chat, state, chat)

    expect(state.usage).to include(input_tokens: 30, output_tokens: 5, cached_tokens: 170)
    expect(state.usage[:cost_usd]).to be_within(1e-10).of(0.03)
  end

  it "does not bill the first round twice when continuing the same chat" do
    allow(chat.provider).to receive(:complete).and_return(message(input: 10, output: 2, cost: 0.01))
    2.times do
      chat.ask_later("hello")
      executor.send(:complete_chat, state, chat)
    end

    expect(state.usage).to include(input_tokens: 20, output_tokens: 4)
    expect(state.usage[:cost_usd]).to be_within(1e-10).of(0.02)
  end

  it "accounts a completed generation even when its tool then raises" do
    bad = Class.new(RubyLLM::Tool) do
      def name = "bad"
      def execute = raise(ArgumentError, "broken tool")
    end.new
    chat.with_tools(bad)
    call = RubyLLM::ToolCall.new(id: "bad", name: "bad", arguments: {})
    allow(chat.provider).to receive(:complete)
      .and_return(message(input: 10, output: 2, cost: 0.01, calls: { "bad" => call }))
    chat.ask_later("hello")

    expect { executor.send(:complete_chat, state, chat) }.to raise_error(ArgumentError, "broken tool")
    expect(state.usage).to include(input_tokens: 10, output_tokens: 2, cost_usd: 0.01)
  end

  it "keeps unreported tokens and costs unknown" do
    usage = executor.send(:usage_of, message(input: nil, output: nil))
    expect(usage).not_to have_key(:input_tokens)
    expect(usage).not_to have_key(:output_tokens)
    expect(usage).not_to have_key(:total_tokens)
    expect(usage[:cost_usd]).to be_nil
  end

  it "does not turn a partially unknown cost into a complete total" do
    usage = executor.send(:merge_usage, { input_tokens: 1, cost_usd: 0.01 },
                          { input_tokens: 2, cost_usd: nil })
    expect(usage).to include(input_tokens: 3, cost_usd: nil)
  end
end
