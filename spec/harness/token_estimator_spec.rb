# frozen_string_literal: true

RSpec.describe Harness::TokenEstimator do
  it "estima length/4" do
    expect(described_class.estimate("a" * 400)).to eq(100)
  end

  it "arredonda para cima (ceil)" do
    expect(described_class.estimate("abc")).to eq(1)
  end

  it "string vazia -> 0" do
    expect(described_class.estimate("")).to eq(0)
  end

  it "nil -> 0, sem exceção" do
    expect(described_class.estimate(nil)).to eq(0)
  end

  it "retorna Integer" do
    expect(described_class.estimate("qualquer")).to be_a(Integer)
  end
end
