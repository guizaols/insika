# frozen_string_literal: true

require "spec_helper"

# RFC-0032 C2: the ONE parser every consumer shares (fold, doctor, Studio,
# freeze command). Pure value object — never touches a store. `parse` returns
# nil on a malformed shape (D8: the fold skips, the doctor explains); `parse!`
# raises Insika::ValidationError naming the defect.
RSpec.describe Insika::FunnelDeclaration do
  let(:valid) do
    { "stages" => %w[greeted qualified cart paid],
      "advance_on" => { "pix_paid" => "paid", "abandoned_cart" => "cart" },
      "primary" => "paid", "attribution_window" => "72h" }
  end

  describe ".parse / .parse!" do
    it "parses a complete declaration" do
      decl = described_class.parse(valid)
      expect(decl).not_to be_nil
      expect(decl.stages).to eq(%w[greeted qualified cart paid])
      expect(decl.primary).to eq("paid")
      expect(decl.attribution_window).to eq("72h")
    end

    it "string-key and symbol-key input give equal objects" do
      sym = valid.transform_keys(&:to_sym)
      sym = sym.merge(advance_on: valid["advance_on"].transform_keys(&:to_sym))
      expect(described_class.parse(sym)).to eq(described_class.parse(valid))
    end

    it "returns nil for a non-Hash input" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("nope")).to be_nil
    end

    it "parse! raises ValidationError naming the field" do
      expect { described_class.parse!(valid.merge("primary" => "outside")) }
        .to raise_error(Insika::ValidationError, /primary/)
    end

    it "parse rescue-returns nil where parse! raises" do
      expect(described_class.parse(valid.merge("primary" => "outside"))).to be_nil
    end
  end

  describe "validation rules" do
    def invalid(hash)
      described_class.parse(hash)
    end

    it "stages: missing, empty, non-string or duplicate -> nil" do
      expect(invalid(valid.except("stages"))).to be_nil
      expect(invalid(valid.merge("stages" => []))).to be_nil
      expect(invalid(valid.merge("stages" => [1, 2]))).to be_nil
      expect(invalid(valid.merge("stages" => ["", "paid"]))).to be_nil
      expect(invalid(valid.merge("stages" => %w[paid paid cart]))).to be_nil
    end

    it "advance_on: missing, empty or a value outside stages -> nil" do
      expect(invalid(valid.except("advance_on"))).to be_nil
      expect(invalid(valid.merge("advance_on" => {}))).to be_nil
      expect(invalid(valid.merge("advance_on" => { "pix_paid" => "nope" }))).to be_nil
      expect(invalid(valid.merge("advance_on" => { "x" => "" }))).to be_nil
    end

    it "advance_on keys are free (never validated against a closed set)" do
      decl = invalid(valid.merge("advance_on" => { "shiny_unknown_kind" => "paid" }))
      expect(decl).not_to be_nil
      expect(decl.advance_on).to eq("shiny_unknown_kind" => "paid")
    end

    it "primary: missing or outside stages -> nil" do
      expect(invalid(valid.except("primary"))).to be_nil
      expect(invalid(valid.merge("primary" => "nope"))).to be_nil
    end

    it "attribution_window: must match /\\A\\d+h\\z/" do
      expect(invalid(valid.merge("attribution_window" => "72"))).to be_nil
      expect(invalid(valid.merge("attribution_window" => "72h30m"))).to be_nil
      expect(invalid(valid.merge("attribution_window" => "three"))).to be_nil
      expect(invalid(valid.except("attribution_window"))).to be_nil
    end

    it "parse! names the defect for each rule" do
      expect { described_class.parse!(valid.merge("stages" => [])) }
        .to raise_error(Insika::ValidationError, /stages/)
      expect { described_class.parse!(valid.merge("advance_on" => { "x" => "nope" })) }
        .to raise_error(Insika::ValidationError, /advance_on/)
      expect { described_class.parse!(valid.merge("attribution_window" => "x")) }
        .to raise_error(Insika::ValidationError, /attribution_window/)
    end
  end

  describe "accessors" do
    let(:decl) { described_class.parse(valid) }

    it "index_of returns the position in the declared order" do
      expect(decl.index_of("greeted")).to eq(0)
      expect(decl.index_of("qualified")).to eq(1)
      expect(decl.index_of("paid")).to eq(3)
      expect(decl.index_of("handoff")).to be_nil
    end

    it "first_stage is the denominator" do
      expect(decl.first_stage).to eq("greeted")
    end

    it "window_hours turns '72h' into 72" do
      expect(decl.window_hours).to eq(72)
    end

    it "multiple kinds mapping to one stage is valid" do
      multi = valid.merge("advance_on" => { "pix_paid" => "paid", "card_paid" => "paid" })
      expect(described_class.parse(multi)).not_to be_nil
      expect(described_class.parse(multi).index_of("paid")).to eq(3)
    end
  end
end
