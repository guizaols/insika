# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Safety::SafeResponses do
  it "returns a distinct non-blank reply per category" do
    %i[injection sexual abuse escalate default].each do |cat|
      expect(described_class.for(cat)).to be_a(String).and(satisfy { |s| !s.strip.empty? })
    end
  end

  it "the injection reply never echoes internal config" do
    expect(described_class.for(:injection)).to include("instruções internas")
  end

  it "an unknown/nil category falls back to the neutral default (never blank/error)" do
    expect(described_class.for(nil)).to eq(described_class::DEFAULTS[:default])
    expect(described_class.for(:bogus)).to eq(described_class::DEFAULTS[:default])
  end

  it "accepts a string category" do
    expect(described_class.for("abuse")).to eq(described_class::DEFAULTS[:abuse])
  end
end
