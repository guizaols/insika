# frozen_string_literal: true

require "spec_helper"

# RFC-0029 C6 — the pack's deterministic claim extractor + membership check.
# REVIEW-DECISION: grounding is SKU-only (the name half could never flag — cut).
RSpec.describe Insika::GroundingMatcher do
  let(:matcher) { described_class.build({ "sku" => '\b[A-Z]{2,4}\d{4,8}\b' }) }

  describe "references" do
    it "finds SKU-pattern matches in the text, deduped" do
      expect(matcher.references("the TNSR1234 and AB123456, then TNSR1234 again"))
        .to eq(%w[TNSR1234 AB123456])
    end

    it "an empty matcher (no sku) -> no refs" do
      empty = described_class.build({})
      expect(empty.references("TNSR1234")).to eq([])
    end

    it "capture groups / alternation never inject nils or empties (the full match wins)" do
      grouped = described_class.build({ "sku" => '\b([A-Z]{2}\d{4})|(ZZ\d+)\b' })
      expect(grouped.references("temos ZZ1234 e nada mais"))
        .to eq(["ZZ1234"])
    end
  end

  describe "ungrounded" do
    it "a reference in the evidence ids is grounded" do
      expect(matcher.ungrounded(["TNSR1234"], evidence_ids: %w[TNSR1234])).to eq([])
    end

    it "a reference not in the evidence set is ungrounded" do
      expect(matcher.ungrounded(%w[TNSR9999 TNSR1234], evidence_ids: %w[TNSR1234]))
        .to eq(["TNSR9999"])
    end
  end

  describe "regex safety" do
    it "bakes a timeout so a pathological pack pattern cannot hang the reactor" do
      expect(matcher.instance_variable_get(:@sku).timeout).to eq(Insika::GroundingMatcher::REGEX_TIMEOUT)
    end

    it "an uncompileable sku raises at build (never at the turn)" do
      expect { described_class.build({ "sku" => "([" }) }
        .to raise_error(Insika::ValidationError, /sku does not compile/)
    end
  end
end
