# frozen_string_literal: true

require "spec_helper"

# LLM config v2: the resolved model decision + its application to the chat.
RSpec.describe Insika::ModelSelection do
  # Records the fluent with_* calls the way a RubyLLM chat exposes them. Named
  # uniquely to avoid clobbering the shared spec/support/fake_chat.rb constant.
  recording_chat = Class.new do
    attr_reader :calls

    def initialize = (@calls = [])
    def with_temperature(v) = (@calls << [:with_temperature, v]; self)
    def with_thinking(effort:) = (@calls << [:with_thinking, effort]; self)
    def with_max_output_tokens(v) = (@calls << [:with_max_output_tokens, v]; self)
    def with_provider_options(params) = (@calls << [:with_provider_options, params]; self)
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
    it "configures a real RubyLLM chat for a custom model without registry thinking controls" do
      llm = RubyLLM.context { |config| config.deepseek_api_key = "test-key" }
      chat = llm.chat(model: "custom-deepseek-model", provider: :deepseek, assume_model_exists: true)
      routing = { "order" => ["DeepInfra"] }
      described_class.new(model: "custom-deepseek-model", provider: :deepseek,
                          params: { max_tokens: 256, thinking: "off", provider_routing: routing }).apply_params(chat)

      expect(chat.max_output_tokens).to eq(256)
      expect(chat.provider_options).to eq(thinking: { type: "disabled" }, provider: routing)
      expect(chat.thinking).to be_nil
    end

    it "applies only PRESENT params (RubyLLM raises on nil)" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { temperature: 0.2, max_tokens: 200, thinking: "high" }).apply_params(chat)
      expect(chat.calls).to eq([
                                 [:with_temperature, 0.2],
                                 [:with_max_output_tokens, 200],
                                 [:with_thinking, :high]
                               ])
    end

    it "maps the public max_tokens setting to the native output cap" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { max_tokens: 512 }).apply_params(chat)
      expect(chat.calls).to eq([[:with_max_output_tokens, 512]])
    end

    # Which UPSTREAM serves the model, for a gateway that has several. Authored as
    # `provider_routing`, emitted under the wire key `provider` — and in the same
    # provider options as the reasoning toggle.
    it "sends provider_routing as the payload's provider key" do
      chat = fake_chat_class.new
      routing = { "order" => ["DeepInfra"], "allow_fallbacks" => false }
      described_class.new(model: "m", params: { provider_routing: routing, max_tokens: 128 }).apply_params(chat)
      expect(chat.calls).to eq([[:with_max_output_tokens, 128], [:with_provider_options, { provider: routing }]])
    end

    it "ignores a provider_routing that is not a hash" do
      chat = fake_chat_class.new
      described_class.new(model: "m", params: { provider_routing: "DeepInfra" }).apply_params(chat)
      expect(chat.calls).to be_empty
    end

    it "applies the token cap alongside the provider reasoning toggle" do
      chat = fake_chat_class.new
      described_class.new(model: "m", provider: :deepseek,
                          params: { max_tokens: 300, thinking: "off" }).apply_params(chat)
      expect(chat.calls).to eq([[:with_max_output_tokens, 300], [:with_provider_options, { thinking: { type: "disabled" } }]])
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

  # 4-layer reasoning control: the resolved `thinking` maps to the provider wire.
  describe "the reasoning toggle" do
    def sel(thinking, provider: :deepseek)
      described_class.new(model: "m", provider: provider, params: { thinking: thinking })
    end

    it "off disables DeepSeek thinking through provider options" do
      chat = fake_chat_class.new
      sel("off").apply_params(chat)
      expect(chat.calls).to eq([[:with_provider_options, { thinking: { type: "disabled" } }]])
    end

    it "on enables DeepSeek thinking through provider options" do
      chat = fake_chat_class.new
      sel("on").apply_params(chat)
      expect(chat.calls).to eq([[:with_provider_options, { thinking: { type: "enabled" } }]])
    end

    it "an effort -> with_thinking(effort:) (reasoning_effort), NOT the toggle param" do
      chat = fake_chat_class.new
      sel("medium").apply_params(chat)
      expect(chat.calls).to eq([[:with_thinking, :medium]])
    end

    it "nil provider (platform default = DeepSeek here) still applies the toggle" do
      chat = fake_chat_class.new
      sel("off", provider: nil).apply_params(chat)
      expect(chat.calls).to eq([[:with_provider_options, { thinking: { type: "disabled" } }]])
    end

    it "gates the toggle to DeepSeek: a non-DeepSeek provider gets no thinking param" do
      chat = fake_chat_class.new
      sel("off", provider: :openai).apply_params(chat)
      expect(chat.calls).to eq([]) # toggle wire not mapped for this provider yet
    end

    it "duck-typed: a chat without provider options is skipped, not crashed" do
      bare = Object.new
      expect { sel("off").apply_params(bare) }.not_to raise_error
    end
  end
end
