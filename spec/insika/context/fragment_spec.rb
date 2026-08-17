# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ContextFragment do
  it "applies defaults in .build (priority 50, tokens nil, pinned false)" do
    f = described_class.build(content: "oi", placement: :system, source: "prov")

    expect(f.priority).to eq(50)
    expect(f.tokens).to be_nil
    expect(f.pinned).to be(false)
    expect(f.content).to eq("oi")
    expect(f.placement).to eq(:system)
    expect(f.source).to eq("prov")
  end

  it "accepts overrides" do
    f = described_class.build(content: "x", placement: :history, source: "s",
                              priority: 79, tokens: 10, pinned: true)

    expect([f.priority, f.tokens, f.pinned]).to eq([79, 10, true])
  end

  # Labels are {name, reason} in STRING keys, because they are written straight into
  # the context trace and into events as JSON — one shape, no reader defending
  # against two.
  describe "labels" do
    def labels_for(raw) = described_class.build(content: "x", placement: :system, source: "s", labels: raw).labels

    it "defaults to []" do
      expect(labels_for(nil)).to eq([])
    end

    it "normalizes symbol keys to string keys" do
      expect(labels_for([{ name: "presente", reason: "trigger:presente" }]))
        .to eq([{ "name" => "presente", "reason" => "trigger:presente" }])
    end

    it "accepts a bare string as a reason-less label" do
      expect(labels_for(["mapa"])).to eq([{ "name" => "mapa" }])
    end

    it "omits an absent reason rather than storing a nil" do
      expect(labels_for([{ "name" => "mapa", "reason" => nil }])).to eq([{ "name" => "mapa" }])
    end

    it "freezes each label (a Data field that a caller could still mutate is not immutable)" do
      expect(labels_for([{ name: "mapa", reason: "eager" }]).first).to be_frozen
    end
  end

  it "is immutable (Data); with returns a copy" do
    f = described_class.build(content: "x", placement: :system, source: "s")

    expect { f.instance_variable_set(:@content, "y") }.to raise_error(FrozenError)
    copy = f.with(tokens: 5)
    expect(copy.tokens).to eq(5)
    expect(f.tokens).to be_nil # original untouched
  end

  describe "layer (RFC-0030 C1)" do
    it "defaults to nil in .build (reads as :volatile everywhere it is consumed)" do
      expect(described_class.build(content: "x", placement: :system, source: "s").layer).to be_nil
    end

    it "round-trips an explicit layer" do
      f = described_class.build(content: "x", placement: :system, source: "s", layer: :identity)
      expect(f.layer).to eq(:identity)
    end

    it "with preserves the layer" do
      f = described_class.build(content: "x", placement: :system, source: "s", layer: :identity)
      expect(f.with(tokens: 5).layer).to eq(:identity)
    end
  end
end
