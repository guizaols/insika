# frozen_string_literal: true

RSpec.describe "Insika errors" do
  describe "hierarchy" do
    [
      Insika::ValidationError, Insika::NotFoundError, Insika::PolicyDenied,
      Insika::ContextError, Insika::ProviderError, Insika::StoreError,
      Insika::CancelledError, Insika::TimeoutError, Insika::CapabilityError,
      Insika::CapabilityUnavailable, Insika::CapabilityAmbiguous
    ].each do |klass|
      it "#{klass} inherits from Insika::Error" do
        expect(klass).to be < Insika::Error
      end
    end

    it "CapabilityUnavailable/Ambiguous inherit from CapabilityError" do
      expect(Insika::CapabilityUnavailable).to be < Insika::CapabilityError
      expect(Insika::CapabilityAmbiguous).to be < Insika::CapabilityError
    end

    it "Insika::Error inherits from StandardError" do
      expect(Insika::Error).to be < StandardError
    end
  end

  describe Insika::PolicyDenied do
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

  describe Insika::ContextError do
    it "exposes provider" do
      expect(described_class.new(provider: "session").provider).to eq("session")
    end
  end

  describe Insika::TimeoutError do
    it "exposes stage" do
      expect(described_class.new(stage: :turn).stage).to eq(:turn)
    end
  end

  describe Insika::CapabilityUnavailable do
    it "exposes capability and the default message includes it" do
      err = described_class.new(capability: "browse")
      expect(err.capability).to eq("browse")
      expect(err.message).to include("browse")
    end

    it "accepts an explicit message" do
      expect(described_class.new("msg custom", capability: "browse").message).to eq("msg custom")
    end
  end

  describe Insika::CapabilityAmbiguous do
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
