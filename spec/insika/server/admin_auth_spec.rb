# frozen_string_literal: true

require "spec_helper"
require_relative "../../../server/admin_auth"

# doc 07 §7: no token -> 503 (disabled), wrong/absent -> 401, correct -> 200.
RSpec.describe Insika::Server::AdminAuth do
  describe ".check (fail-closed)" do
    it "no token configured -> :disabled" do
      expect(described_class.check(nil, "Bearer x")).to eq(:disabled)
    end

    it "empty token configured -> :disabled (an empty string is never a token)" do
      expect(described_class.check("", "Bearer x")).to eq(:disabled)
    end

    it "wrong token -> :unauthorized" do
      expect(described_class.check("s3cret", "Bearer nope")).to eq(:unauthorized)
    end

    it "no header -> :unauthorized" do
      expect(described_class.check("s3cret", nil)).to eq(:unauthorized)
    end

    it "format without 'Bearer ' -> :unauthorized" do
      expect(described_class.check("s3cret", "s3cret")).to eq(:unauthorized)
      expect(described_class.check("s3cret", "Basic s3cret")).to eq(:unauthorized)
    end

    it "correct token -> :ok" do
      expect(described_class.check("s3cret", "Bearer s3cret")).to eq(:ok)
    end

    it "uses constant-time comparison (secure_compare)" do
      expect(Rack::Utils).to receive(:secure_compare).with("s3cret", "s3cret").and_call_original
      described_class.check("s3cret", "Bearer s3cret")
    end
  end
end
