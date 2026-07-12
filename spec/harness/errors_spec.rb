# frozen_string_literal: true

RSpec.describe "Harness errors" do
  describe "hierarquia" do
    [
      Harness::ValidationError, Harness::NotFoundError, Harness::PolicyDenied,
      Harness::ContextError, Harness::ProviderError, Harness::StoreError,
      Harness::CancelledError, Harness::TimeoutError, Harness::CapabilityError,
      Harness::CapabilityUnavailable, Harness::CapabilityAmbiguous
    ].each do |klass|
      it "#{klass} herda de Harness::Error" do
        expect(klass).to be < Harness::Error
      end
    end

    it "CapabilityUnavailable/Ambiguous herdam de CapabilityError" do
      expect(Harness::CapabilityUnavailable).to be < Harness::CapabilityError
      expect(Harness::CapabilityAmbiguous).to be < Harness::CapabilityError
    end

    it "Harness::Error herda de StandardError" do
      expect(Harness::Error).to be < StandardError
    end
  end

  describe Harness::PolicyDenied do
    it "expõe policy e reason" do
      err = described_class.new(policy: "x", reason: "y")
      expect(err.policy).to eq("x")
      expect(err.reason).to eq("y")
    end

    it "gera mensagem default com policy e reason" do
      err = described_class.new(policy: "x", reason: "y")
      expect(err.message).to include("x").and include("y")
    end

    it "aceita mensagem explícita" do
      expect(described_class.new("msg", policy: "x").message).to eq("msg")
    end
  end

  describe Harness::ContextError do
    it "expõe provider" do
      expect(described_class.new(provider: "session").provider).to eq("session")
    end
  end

  describe Harness::TimeoutError do
    it "expõe stage" do
      expect(described_class.new(stage: :turn).stage).to eq(:turn)
    end
  end

  describe Harness::CapabilityUnavailable do
    it "expõe capability e mensagem default a inclui" do
      err = described_class.new(capability: "browse")
      expect(err.capability).to eq("browse")
      expect(err.message).to include("browse")
    end

    it "aceita mensagem explícita" do
      expect(described_class.new("msg custom", capability: "browse").message).to eq("msg custom")
    end
  end

  describe Harness::CapabilityAmbiguous do
    it "expõe capability e candidates; mensagem menciona a capability" do
      err = described_class.new(capability: "browse", candidates: %w[a b])
      expect(err.capability).to eq("browse")
      expect(err.candidates).to eq(%w[a b])
      expect(err.message).to include("browse")
    end

    it "candidates default [] sem ArgumentError" do
      expect { described_class.new(capability: "browse") }.not_to raise_error
      expect(described_class.new(capability: "browse").candidates).to eq([])
    end
  end
end
