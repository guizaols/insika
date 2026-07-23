# frozen_string_literal: true

RSpec.describe Insika::TokenEstimator do
  it "estimates length/4" do
    expect(described_class.estimate("a" * 400)).to eq(100)
  end

  it "rounds up (ceil)" do
    expect(described_class.estimate("abc")).to eq(1)
  end

  it "empty string -> 0" do
    expect(described_class.estimate("")).to eq(0)
  end

  it "nil -> 0, no exception" do
    expect(described_class.estimate(nil)).to eq(0)
  end

  it "returns Integer" do
    expect(described_class.estimate("qualquer")).to be_a(Integer)
  end
end
