# frozen_string_literal: true

require "spec_helper"
require "json"

# Shared coercions at the boundary. `utf8` and `truthy?` are covered here — the two
# with a contract the rest of the engine leans on (JSON-serializability, and one
# reading of "opted in" across every surface); `presence`/`blank?`/`deep_stringify`
# are exercised through the stores that use them.
RSpec.describe Insika::Coercion do
  describe ".truthy?" do
    it "reads what a checkbox, a JSON round-trip or the DSL produce as true" do
      [true, "true", "1", "yes", "on"].each { |v| expect(described_class.truthy?(v)).to be(true) }
    end

    it "everything else is not an opt-in — including a LIST, which is a real value here" do
      [nil, false, "false", "0", "", ["formato"], 1].each { |v| expect(described_class.truthy?(v)).to be(false) }
    end
  end

  describe ".utf8" do
    it "re-tags BINARY bytes that are really UTF-8" do
      result = described_class.utf8("ação 🚀".b)

      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to eq("ação 🚀")
    end

    it "leaves a valid UTF-8 string untouched" do
      expect(described_class.utf8("café")).to eq("café")
    end

    it "scrubs invalid bytes instead of propagating them" do
      result = described_class.utf8("ok \xC3(".b)

      expect(result).to be_valid_encoding
      expect { JSON.generate(v: result) }.not_to raise_error
    end

    it "handles a frozen input (never mutates the caller's string)" do
      input = "não".b.freeze

      expect(described_class.utf8(input)).to eq("não")
      expect(input.encoding).to eq(Encoding::BINARY)
    end

    it "nil -> empty string" do
      expect(described_class.utf8(nil)).to eq("")
    end
  end
end
