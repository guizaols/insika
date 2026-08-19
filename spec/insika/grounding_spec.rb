# frozen_string_literal: true

require "spec_helper"

#   — the profile-facing half: parse the pack's `grounding` data into
# the per-turn Grounding object (mode + matcher).
RSpec.describe Insika::Grounding do
  it "nil / false -> nil (off)" do
    expect(described_class.parse(nil)).to be_nil
    expect(described_class.parse(false)).to be_nil
  end

  it "defaults the mode to :flag when absent/unknown" do
    expect(described_class.parse({}).mode).to eq("flag")
    expect(described_class.parse({ "mode" => "bogus" }).mode).to eq("flag")
  end

  it "honors the declared mode" do
    expect(described_class.parse({ "mode" => "enforce" }).enforce?).to be(true)
    expect(described_class.parse({ "mode" => "enforce" }).off?).to be(false)
    expect(described_class.parse({ "mode" => "off" }).off?).to be(true)
    expect(described_class.parse({ "mode" => "flag" }).enforce?).to be(false)
  end

  it "builds the matcher from the pack's sku (deep-stringified)" do
    g = described_class.parse({ "mode" => "flag", "matcher" => { "sku" => "\\d+" } })
    expect(g.matcher).to be_a(Insika::GroundingMatcher)
    expect(g.matcher.references("SKU 123 X")).to eq(["123"])
  end

  it "an empty matcher config still builds (harmless but useless; the pack's problem)" do
    g = described_class.parse({ "mode" => "flag", "matcher" => {} })
    expect(g.matcher.references("any text")).to eq([])
  end

  it "raises ValidationError when the matcher sku does not compile" do
    expect { described_class.parse({ "mode" => "flag", "matcher" => { "sku" => "([" } }) }
      .to raise_error(Insika::ValidationError, /sku does not compile/)
  end

  it "raises ValidationError when the sku exceeds the length cap" do
    long = "a" * (Insika::Grounding::SKU_MAX + 1)
    expect { described_class.parse({ "mode" => "flag", "matcher" => { "sku" => long } }) }
      .to raise_error(Insika::ValidationError, /exceeds/)
  end
end
