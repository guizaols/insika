# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::AgentDefaults do
  let(:config_store) { Insika::ConfigStore.new(store: Insika::Stores::Memory.new) }
  let(:settings) { Insika::SettingsStore.new(config_store: config_store) }
  let(:stored) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:source) { described_class::ProfileSource.new(stored, settings_store: settings) }
  let(:platform_reliability) { { "timeout" => 45, "fallback" => ["openai/gpt-x"] } }

  before do
    stored.put(Insika::AgentProfile.build(id: "plain", model: "m"))
    stored.put(Insika::AgentProfile.build(id: "own", model: "m", reliability: { "timeout" => 10 }))
    settings.put_agent_defaults("reliability" => platform_reliability,
                                "knowledge" => { "extract" => true, "retrieve" => true })
  end

  it "an agent without the field runs with the platform's" do
    profile = source.fetch("plain")
    expect(profile.reliability).to eq(platform_reliability)
    expect(profile.knowledge).to include("extract" => true, "retrieve" => true)
  end

  it "an agent with its own value keeps it whole" do
    expect(source["own"].reliability).to eq("timeout" => 10)
  end

  it "the stored agent is untouched, so saving it never copies a default in" do
    source.fetch("plain")
    expect(stored.fetch("plain").reliability).to be_nil
  end

  it "only the inheritable fields are filled" do
    settings.put_agent_defaults("tools_allow" => ["x"])
    expect(source.fetch("plain").tools_allow).to be_nil
  end

  it "a cleared default stops being inherited" do
    settings.put_agent_defaults("knowledge" => nil)
    expect(source.fetch("plain").knowledge).to be_nil
    expect(source.fetch("plain").reliability).to eq(platform_reliability)
  end

  it "keeps the source contract: all, ids, nil for an unknown id" do
    expect(source.all.map(&:reliability)).to contain_exactly(platform_reliability, { "timeout" => 10 })
    expect(source.ids).to contain_exactly("plain", "own")
    expect(source.fetch("missing")).to be_nil
  end

  it "the defaults are replaced whole, so a key removed in the form is gone" do
    settings.put_agent_defaults("reliability" => { "timeout" => 5 })
    expect(source.fetch("plain").reliability).to eq("timeout" => 5)
  end

  it "never writes through: the agent's own source is the only door, and own() returns it" do
    expect { source.put(stored.fetch("plain")) }.to raise_error(Insika::Error, /own source/)
    expect(described_class.own(source)).to be(stored)
    expect(described_class.own(stored)).to be(stored)
  end

  it "a default that no longer builds leaves the agent on its own values instead of failing the turn" do
    bad = { "rerank" => { "provider" => nil } }
    allow(settings).to receive(:get).and_wrap_original { |m| m.call.merge("agent_defaults" => { "knowledge" => bad }) }
    profile = nil
    expect { profile = source.fetch("plain") }.to output(/agent defaults/).to_stderr
    expect(profile.knowledge).to be_nil
    expect(source.all.map(&:knowledge)).to all(be_nil) # warned once per change, not per read
  end

  it "normalizes the defaults once per change, not once per read" do
    static = Insika::StaticProfileSource.new("plain" => Insika::AgentProfile.build(id: "plain", model: "m"))
    reads = described_class::ProfileSource.new(static, settings_store: settings)
    builds = 0
    allow(Insika::AgentProfile).to receive(:build).and_wrap_original { |m, **kw| builds += 1; m.call(**kw) }
    reads.fetch("plain")
    after_first = builds
    3.times { reads.fetch("plain") }
    reads.all
    expect(builds).to eq(after_first)
    expect(reads.fetch("plain").reliability).to eq(platform_reliability)
    expect(reads.fetch("plain").reliability).to be_frozen

    settings.put_agent_defaults("reliability" => { "timeout" => 7 })
    expect(reads.fetch("plain").reliability).to eq("timeout" => 7)
  end
end
