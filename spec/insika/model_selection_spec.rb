# frozen_string_literal: true

require "spec_helper"

# LLM config v2 (§10): the resolved model decision + its application to the chat.
RSpec.describe Insika::ModelSelection do
  # Records the fluent with_* calls the way a RubyLLM chat exposes them. Named
  # uniquely to avoid clobbering the shared spec/support/fake_chat.rb constant.
  # It may ONLY expose methods the real RubyLLM::Chat has (ruby_llm_contract_spec
  # guards that): a double that answers a setter the gem lacks turns this file
  # into theater — which is how `with_max_output_tokens` passed for months while
  # max_tokens never reached a provider.
  recording_chat = Class.new do
    attr_reader :calls

    def initialize = (@calls = [])
    def with_temperature(v) = (@calls << [:with_temperature, v]; self)
    def with_thinking(effort:) = (@calls << [:with_thinking, effort]; self)
    def with_params(**params) = (@calls << [:with_params, params]; self)
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
                                 [:with_params, { max_tokens: 200 }],
                                 [:with_thinking, :high]
                               ])
    end

    # max_tokens has no with_* setter in the gem — it rides with_params, which is
    # deep-merged OVER the provider payload (and so also overrides Anthropic's
    # registry-derived cap).
    it "sends max_tokens as a provider param" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { max_tokens: 512 }).apply_params(chat)
      expect(chat.calls).to eq([[:with_params, { max_tokens: 512 }]])
    end

    # with_params REPLACES the gem's whole params hash: two calls would drop the
    # first one's keys, so max_tokens + the reasoning toggle must travel together.
    it "merges max_tokens and the reasoning toggle into ONE with_params call" do
      chat = fake_chat_class.new
      described_class.new(model: "m", provider: :deepseek,
                          params: { max_tokens: 300, thinking: "off" }).apply_params(chat)
      expect(chat.calls).to eq([[:with_params, { max_tokens: 300, thinking: { type: "disabled" } }]])
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

  # §10 4-layer reasoning control: the resolved `thinking` maps to the provider wire.
  describe "the reasoning toggle" do
    def sel(thinking, provider: :deepseek)
      described_class.new(model: "m", provider: provider, params: { thinking: thinking })
    end

    it "off -> with_params(thinking: {type: disabled}) (ruby_llm can't disable via with_thinking)" do
      chat = fake_chat_class.new
      sel("off").apply_params(chat)
      expect(chat.calls).to eq([[:with_params, { thinking: { type: "disabled" } }]])
    end

    it "on -> with_params(thinking: {type: enabled})" do
      chat = fake_chat_class.new
      sel("on").apply_params(chat)
      expect(chat.calls).to eq([[:with_params, { thinking: { type: "enabled" } }]])
    end

    it "an effort -> with_thinking(effort:) (reasoning_effort), NOT the toggle param" do
      chat = fake_chat_class.new
      sel("medium").apply_params(chat)
      expect(chat.calls).to eq([[:with_thinking, :medium]])
    end

    it "nil provider (platform default = DeepSeek here) still applies the toggle" do
      chat = fake_chat_class.new
      sel("off", provider: nil).apply_params(chat)
      expect(chat.calls).to eq([[:with_params, { thinking: { type: "disabled" } }]])
    end

    it "gates the toggle to DeepSeek: a non-DeepSeek provider gets no thinking param" do
      chat = fake_chat_class.new
      sel("off", provider: :openai).apply_params(chat)
      expect(chat.calls).to eq([]) # toggle wire not mapped for this provider yet
    end

    it "duck-typed: a chat without with_params is skipped, not crashed" do
      bare = Object.new
      expect { sel("off").apply_params(bare) }.not_to raise_error
    end
  end
end
