# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/admin_auth"

# doc 07 §7: sem token -> 503 (disabled), errado/ausente -> 401, certo -> 200.
RSpec.describe Harness::Server::AdminAuth do
  describe ".check (fail-closed)" do
    it "sem token configurado -> :disabled" do
      expect(described_class.check(nil, "Bearer x")).to eq(:disabled)
    end

    it "token vazio configurado -> :disabled (string vazia nunca é token)" do
      expect(described_class.check("", "Bearer x")).to eq(:disabled)
    end

    it "token errado -> :unauthorized" do
      expect(described_class.check("s3cret", "Bearer nope")).to eq(:unauthorized)
    end

    it "sem header -> :unauthorized" do
      expect(described_class.check("s3cret", nil)).to eq(:unauthorized)
    end

    it "formato sem 'Bearer ' -> :unauthorized" do
      expect(described_class.check("s3cret", "s3cret")).to eq(:unauthorized)
      expect(described_class.check("s3cret", "Basic s3cret")).to eq(:unauthorized)
    end

    it "token certo -> :ok" do
      expect(described_class.check("s3cret", "Bearer s3cret")).to eq(:ok)
    end

    it "usa comparação em tempo constante (secure_compare)" do
      expect(Rack::Utils).to receive(:secure_compare).with("s3cret", "s3cret").and_call_original
      described_class.check("s3cret", "Bearer s3cret")
    end
  end
end
