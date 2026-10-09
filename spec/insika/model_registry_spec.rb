# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ModelRegistry do
  let(:backend) { Insika::Stores::Memory.new }
  let(:now) { Time.utc(2026, 10, 8, 12) }
  let(:model) { RubyLLM::Model.new(id: "m-1", provider: "deepseek", pricing: { text_tokens: { standard: { input_per_million: 1.0 } } }) }
  let(:calls) { [] }
  let(:refresher) { -> { calls << :refresh; registry.write([model]) } }
  let(:registry) { described_class.new(store: backend, refresher: refresher) }

  around do |example|
    previous = RubyLLM.config.model_registry_store
    example.run
  ensure
    RubyLLM.config.model_registry_store = previous
    RubyLLM.models.load_from_json
  end

  it "round-trips the catalog through the store in RubyLLM's own format" do
    registry.write([model])
    expect(registry.read.map(&:id)).to eq(["m-1"])
    expect(registry.read.first.to_h[:pricing]).to eq(model.to_h[:pricing])
  end

  it "refreshes once per interval across workers, the others reload the stored catalog" do
    expect(registry.run(now: now)).to include(refreshed: true)
    other = described_class.new(store: backend, refresher: refresher)
    expect(other.run(now: now + 60)).to eq(reloaded: true)
    expect(other.run(now: now + 120)).to be_nil
    expect(calls).to eq([:refresh])
    expect(RubyLLM.models.find("m-1").id).to eq("m-1")
    expect(registry.run(now: Time.now.utc + 86_400 + 1)).to include(refreshed: true)
    expect(calls.size).to eq(2)
  end

  it "keeps the catalog it had when a refresh fails and retries after an hour, not every tick" do
    failing = described_class.new(store: backend, refresher: -> { calls << :boom; raise "down" })
    expect(failing.run(now: now)).to include(refreshed: false)
    expect(failing.run(now: now + 60)).to be_nil
    failing.run(now: now + 3600)
    expect(calls).to eq(%i[boom boom])
  end

  it "does nothing when disabled" do
    expect(described_class.new(store: backend, interval: 0, refresher: refresher).run(now: now)).to be_nil
    expect(calls).to be_empty
  end
end
