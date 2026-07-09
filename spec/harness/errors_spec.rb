# frozen_string_literal: true

RSpec.describe "Harness errors" do
  describe "hierarquia" do
    [
      Harness::ValidationError, Harness::NotFoundError, Harness::PolicyDenied,
      Harness::ContextError, Harness::ProviderError, Harness::StoreError,
      Harness::CancelledError, Harness::TimeoutError
    ].each do |klass|
      it "#{klass} herda de Harness::Error" do
        expect(klass).to be < Harness::Error
      end
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
end
