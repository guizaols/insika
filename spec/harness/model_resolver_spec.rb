# frozen_string_literal: true

require "spec_helper"

# LLM config v2 (§10): Chat > Agent > platform default + model_policy + fallbacks.
RSpec.describe Harness::ModelResolver do
  # Minimal settings_store: only #get is consumed by the resolver.
  def settings(overrides = {})
    Class.new do
      def initialize(h) = (@h = h)
      def get = @h
    end.new(Harness::SettingsStore::DEFAULTS.merge(overrides))
  end

  # Session double carrying only what the resolver reads (#vars).
  def session_with(vars) = Struct.new(:vars).new(vars)

  def pinned_session(model:, provider: nil)
    slot = { "model" => model }
    slot["provider"] = provider if provider
    session_with({ Harness::ModelResolver::SESSION_SLOT => slot })
  end

  def profile(**kw) = Harness::AgentProfile.build(id: "bia", **kw)

  describe "precedence Chat > Agent > platform default" do
    it "uses the agent model when no chat pin" do
      sel = described_class.new(settings_store: settings("default_model" => "plat")).resolve(
        profile: profile(model: "agent-m", provider: :deepseek)
      )
      expect(sel.model).to eq("agent-m")
      expect(sel.provider).to eq(:deepseek)
      expect(sel.source).to eq(:agent)
      expect(sel.pinned?).to be(false)
    end

    it "the chat pin wins over the agent model and is PINNED (fails high, no fallback)" do
      sel = described_class.new(
        settings_store: settings("fallback_models" => ["deepseek/x"])
      ).resolve(
        profile: profile(model: "agent-m", provider: :deepseek),
        session: pinned_session(model: "chat-m", provider: "openai")
      )
      expect(sel.model).to eq("chat-m")
      expect(sel.provider).to eq(:openai)
      expect(sel.source).to eq(:chat)
      expect(sel.pinned?).to be(true)
      expect(sel.fallbacks).to eq([]) # pinned => no silent fallback
    end

    it "falls back to the platform default when the agent has no model" do
      sel = described_class.new(
        settings_store: settings("default_model" => "plat-m", "default_provider" => "deepseek")
      ).resolve(profile: profile) # no model
      expect(sel.model).to eq("plat-m")
      expect(sel.provider).to eq(:deepseek)
      expect(sel.source).to eq(:platform_default)
    end

    it "raises a clear error when NO layer resolves a model" do
      expect do
        described_class.new(settings_store: settings).resolve(profile: profile) # no agent model, no default
      end.to raise_error(Harness::Error, /no model resolved/)
    end

    it "without a settings_store, resolution uses the agent model (pre-v2 parity)" do
      sel = described_class.new.resolve(profile: profile(model: "agent-m"))
      expect(sel.model).to eq("agent-m")
      expect(sel.source).to eq(:agent)
    end
  end

  describe "model_policy enforcement (on the RESOLVED model)" do
    it "denies a chat pin that escapes the agent fence" do
      expect do
        described_class.new(settings_store: settings).resolve(
          profile: profile(model: "agent-m", provider: :deepseek, model_policy: { "allow" => ["deepseek/*"] }),
          session: pinned_session(model: "gpt-4o", provider: "openai")
        )
      end.to raise_error(Harness::PolicyDenied) { |e| expect(e.policy).to eq(:model_policy) }
    end

    it "allows a model inside the fence" do
      sel = described_class.new(settings_store: settings).resolve(
        profile: profile(model: "deepseek-chat", provider: :deepseek, model_policy: { "allow" => ["deepseek/*"] })
      )
      expect(sel.model).to eq("deepseek-chat")
    end
  end

  describe "fallback chain" do
    it "resolves the platform chain, dedupes the primary, filters by policy" do
      sel = described_class.new(
        settings_store: settings("fallback_models" => ["deepseek/deepseek-chat", "openai/gpt-4o", "deepseek/deepseek-reasoner"])
      ).resolve(
        profile: profile(model: "deepseek-chat", provider: :deepseek, model_policy: { "allow" => ["deepseek/*"] })
      )
      # primary (deepseek/deepseek-chat) dropped; openai/gpt-4o filtered by policy;
      # deepseek/deepseek-reasoner survives.
      expect(sel.fallbacks).to eq([{ model: "deepseek-reasoner", provider: :deepseek }])
    end

    it "parses a bare model ref as provider-less" do
      sel = described_class.new(
        settings_store: settings("fallback_models" => ["some-model"])
      ).resolve(profile: profile(model: "agent-m"))
      expect(sel.fallbacks).to eq([{ model: "some-model", provider: nil }])
    end
  end

  describe "generation params" do
    it "normalizes params to the symbol shape, keeping only known keys" do
      sel = described_class.new(settings_store: settings).resolve(
        profile: profile(model: "m", params: { "temperature" => 0.3, "max_tokens" => 100, "bogus" => 1 })
      )
      expect(sel.params).to eq(temperature: 0.3, max_tokens: 100)
    end
  end

  # §10 4-layer reasoning control: thinking resolved Chat > Agent > Model > Global.
  describe "reasoning (thinking) resolution across layers" do
    def resolve_thinking(agent: nil, chat: nil, global: nil, model_params: nil, model: "m", provider: :deepseek)
      overrides = {}
      overrides["thinking"] = global unless global.nil?
      overrides["model_params"] = model_params unless model_params.nil?
      prof = profile(model: model, provider: provider, params: agent ? { "thinking" => agent } : {})
      sess = chat ? session_with({ Harness::ModelResolver::SESSION_SLOT => { "thinking" => chat } }) : nil
      described_class.new(settings_store: settings(overrides)).resolve(profile: prof, session: sess).params[:thinking]
    end

    it "nothing set anywhere -> no thinking (provider default)" do
      expect(resolve_thinking).to be_nil
    end

    it "global only" do
      expect(resolve_thinking(global: "off")).to eq("off")
    end

    it "per-model overrides global (matched by provider/model ref)" do
      expect(resolve_thinking(global: "high", model_params: { "deepseek/m" => { "thinking" => "off" } })).to eq("off")
    end

    it "per-model matches the bare model id too" do
      expect(resolve_thinking(global: "high", model_params: { "m" => { "thinking" => "low" } })).to eq("low")
    end

    it "agent overrides per-model and global" do
      expect(resolve_thinking(agent: "medium", global: "off",
                              model_params: { "deepseek/m" => { "thinking" => "high" } })).to eq("medium")
    end

    it "chat overrides everything (most specific wins)" do
      expect(resolve_thinking(chat: "off", agent: "high", global: "low")).to eq("off")
    end

    it "the chat thinking override applies even without a model pin" do
      # session slot carries thinking but no model -> model still resolves from agent
      expect(resolve_thinking(chat: "on", agent: "high")).to eq("on")
    end
  end
end
