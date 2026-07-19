# frozen_string_literal: true

require "spec_helper"

# LLM config v2 (§10): the resolved model decision + its application to the chat.
RSpec.describe Harness::ModelSelection do
  # Records the fluent with_* calls the way a RubyLLM chat exposes them. Named
  # uniquely to avoid clobbering the shared spec/support/fake_chat.rb constant.
  recording_chat = Class.new do
    attr_reader :calls

    def initialize = (@calls = [])
    def with_temperature(v) = (@calls << [:with_temperature, v]; self)
    def with_max_output_tokens(v) = (@calls << [:with_max_output_tokens, v]; self)
    def with_thinking(effort:) = (@calls << [:with_thinking, effort]; self)
  end
  let(:fake_chat_class) { recording_chat }

  it "defaults: platform_default source, not pinned, no params/fallbacks" do
    sel = described_class.new(model: "m")
    expect(sel.source).to eq(:platform_default)
    expect(sel.pinned?).to be(false)
    expect(sel.params).to eq({})
    expect(sel.fallbacks).to eq([])
  end

  it "assume_model_exists? follows presence of provider (pre-v2 behavior)" do
    expect(described_class.new(model: "m", provider: :deepseek).assume_model_exists?).to be(true)
    expect(described_class.new(model: "m", provider: nil).assume_model_exists?).to be(false)
  end

  describe "#apply_params" do
    it "applies only PRESENT params (RubyLLM raises on nil)" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { temperature: 0.2, max_tokens: 200, thinking: "high" }).apply_params(chat)
      expect(chat.calls).to eq([
                                 [:with_temperature, 0.2],
                                 [:with_max_output_tokens, 200],
                                 [:with_thinking, :high]
                               ])
    end

    it "skips absent params" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { temperature: 0.5 }).apply_params(chat)
      expect(chat.calls).to eq([[:with_temperature, 0.5]])
    end

    it "ignores non-numeric temperature/max_tokens (guards bad input)" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { temperature: "hot", max_tokens: "" }).apply_params(chat)
      expect(chat.calls).to eq([])
    end

    it "is duck-typed: a chat missing a with_* is skipped, not crashed" do
      bare = Object.new
      def bare.with_temperature(_v) = :ok
      expect do
        described_class.new(model: "m", params: { temperature: 0.1, max_tokens: 10 }).apply_params(bare)
      end.not_to raise_error
    end

    it "returns the chat (chainable)" do
      chat = fake_chat_class.new
      expect(described_class.new(model: "m").apply_params(chat)).to be(chat)
    end
  end
end
