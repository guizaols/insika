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

  it "is immutable (Data); with returns a copy" do
    f = described_class.build(content: "x", placement: :system, source: "s")

    expect { f.instance_variable_set(:@content, "y") }.to raise_error(FrozenError)
    copy = f.with(tokens: 5)
    expect(copy.tokens).to eq(5)
    expect(f.tokens).to be_nil # original untouched
  end
end
