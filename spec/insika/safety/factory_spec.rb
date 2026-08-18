# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::Factory do
  def state(guardrails)
    prof = Insika::AgentProfile.build(id: "x", guardrails: guardrails)
    Insika::TurnState.new(task: nil, profile: prof, turn: 1, message: "oi")
  end

  describe "#content_filter_factory" do
    it "builds a fresh OutputFilter when the agent has output guardrails on" do
      f = described_class.new.content_filter_factory
      one = f.call(state(nil))
      two = f.call(state(nil))
      expect(one).to be_a(Insika::Safety::OutputFilter)
      expect(one).not_to be(two) # per-turn instance (stateful)
    end

    it "returns nil when output is off" do
      f = described_class.new.content_filter_factory
      expect(f.call(state("output" => false))).to be_nil
    end

    it "builds the filter from the agent's compiled corpus (RFC-0036 C2)" do
      f = described_class.new.content_filter_factory
      st = state("corpora" => { "languages" => ["en"] })
      filter = f.call(st)
      out = filter.push("cpf 123.456.789-01") + filter.flush
      expect(out).to include("123.456.789-01") # EN corpus: CPF cleared
    end
  end

  describe "moderator model resolution" do
    let(:settings) do
      Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
    end

    it "resolves the per-agent moderator ref into a Moderator" do
      factory = described_class.new(settings_store: settings)
      config = Insika::Safety::Config.from_hash("moderator" => "deepseek/deepseek-chat")
      expect(factory.send(:moderator_for, config)).to be_a(Insika::Safety::Moderator)
    end

    it "'on' falls back to the platform utility_model" do
      settings.update("utility_model" => "deepseek/deepseek-chat")
      factory = described_class.new(settings_store: settings)
      config = Insika::Safety::Config.from_hash("moderator" => "on")
      expect(factory.send(:moderator_for, config)).to be_a(Insika::Safety::Moderator)
    end

    it "'on' with no utility_model configured -> no moderator (deterministic only)" do
      factory = described_class.new(settings_store: settings) # utility_model default nil
      config = Insika::Safety::Config.from_hash("moderator" => "on")
      expect(factory.send(:moderator_for, config)).to be_nil
    end

    it "no moderator opt-in -> nil" do
      factory = described_class.new(settings_store: settings)
      expect(factory.send(:moderator_for, Insika::Safety::Config.from_hash({}))).to be_nil
    end
  end
end
