# frozen_string_literal: true

RSpec.describe "Harness errors" do
  describe "hierarchy" do
    [
      Harness::ValidationError, Harness::NotFoundError, Harness::PolicyDenied,
      Harness::ContextError, Harness::ProviderError, Harness::StoreError,
      Harness::CancelledError, Harness::TimeoutError, Harness::CapabilityError,
      Harness::CapabilityUnavailable, Harness::CapabilityAmbiguous
    ].each do |klass|
      it "#{klass} inherits from Harness::Error" do
        expect(klass).to be < Harness::Error
      end
    end

    it "CapabilityUnavailable/Ambiguous inherit from CapabilityError" do
      expect(Harness::CapabilityUnavailable).to be < Harness::CapabilityError
      expect(Harness::CapabilityAmbiguous).to be < Harness::CapabilityError
    end

    it "Harness::Error inherits from StandardError" do
      expect(Harness::Error).to be < StandardError
    end
  end

  describe Harness::PolicyDenied do
    it "exposes policy and reason" do
      err = described_class.new(policy: "x", reason: "y")
      expect(err.policy).to eq("x")
      expect(err.reason).to eq("y")
    end

    it "generates a default message with policy and reason" do
      err = described_class.new(policy: "x", reason: "y")
      expect(err.message).to include("x").and include("y")
    end

    it "accepts an explicit message" do
      expect(described_class.new("msg", policy: "x").message).to eq("msg")
    end
  end

  describe Harness::ContextError do
    it "exposes provider" do
      expect(described_class.new(provider: "session").provider).to eq("session")
    end
  end

  describe Harness::TimeoutError do
    it "exposes stage" do
      expect(described_class.new(stage: :turn).stage).to eq(:turn)
    end
  end

  describe Harness::CapabilityUnavailable do
    it "exposes capability and the default message includes it" do
      err = described_class.new(capability: "browse")
      expect(err.capability).to eq("browse")
      expect(err.message).to include("browse")
    end

    it "accepts an explicit message" do
      expect(described_class.new("msg custom", capability: "browse").message).to eq("msg custom")
    end
  end

  describe Harness::CapabilityAmbiguous do
    it "exposes capability and candidates; message mentions the capability" do
      err = described_class.new(capability: "browse", candidates: %w[a b])
      expect(err.capability).to eq("browse")
      expect(err.candidates).to eq(%w[a b])
      expect(err.message).to include("browse")
    end

    it "candidates default to [] without ArgumentError" do
      expect { described_class.new(capability: "browse") }.not_to raise_error
      expect(described_class.new(capability: "browse").candidates).to eq([])
    end
  end
end
