# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::SchemaGuard do
  # The shape that motivated the guard: query_filter_pairs is a list of OBJECTS.
  let(:search_schema) do
    {
      "type" => "object",
      "properties" => {
        "query_filter_pairs" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "query" => { "type" => "string" },
              "filters" => { "type" => "object", "properties" => { "brand" => { "type" => "string" } } }
            },
            "required" => ["query"]
          }
        },
        "catalog_mode" => { "type" => "boolean" }
      },
      "required" => ["query_filter_pairs"]
    }
  end

  def violation(args, schema: search_schema) = described_class.violation(schema, args)

  def pairs(value) = violation({ query_filter_pairs: value })

  it "passes a call that matches the schema" do
    expect(pairs([{ "query" => "trufa", "filters" => { "brand" => "Acme" } }])).to be_nil
  end

  it "catches a list of strings where the schema declares a list of objects" do
    msg = pairs(["trufa Acme", "trufas chocolate"])
    expect(msg).to match(/query_filter_pairs\[0\]: expected an object, got a string/)
    expect(msg).to match(/query_filter_pairs\[1\]/)
  end

  it "catches an item missing a nested required property" do
    expect(pairs([{ "filters" => {} }])).to match(/query_filter_pairs\[0\]\.query: missing \(required\)/)
  end

  it "catches a scalar where a list is expected" do
    expect(pairs("trufa")).to match(/query_filter_pairs: expected a list, got a string/)
  end

  it "catches a nested property of the wrong type" do
    expect(pairs([{ "query" => "x", "filters" => { "brand" => %w[a b] } }]))
      .to match(/query_filter_pairs\[0\]\.filters\.brand: expected string, got a list/)
  end

  it "reports missing top-level required params with the historical message" do
    expect(violation({ catalog_mode: true })).to eq("missing required parameter(s): query_filter_pairs")
  end

  it "treats a blank top-level required param as missing (it feeds {{placeholders}})" do
    expect(pairs("")).to match(/missing required parameter/)
  end

  it "ignores properties the schema does not declare" do
    expect(pairs([{ "query" => "x", "surprise" => 1 }])).to be_nil
  end

  it "does not police an optional property that was not sent" do
    expect(pairs([{ "query" => "x" }])).to be_nil
  end

  it "caps how much it reports (the model gets a message, not a dump)" do
    msg = pairs(Array.new(30, "wrong"))
    expect(msg.scan(/expected an object/).length).to eq(described_class::MAX_REPORTED)
  end

  # Providers send "2"/"true" for a number/boolean. That is lossless, and rejecting it
  # would break working tools — so scalars are lenient where structure never is.
  describe "scalar leniency" do
    let(:scalars) do
      { "type" => "object",
        "properties" => { "qty" => { "type" => "integer" }, "price" => { "type" => "number" },
                          "flag" => { "type" => "boolean" }, "note" => { "type" => "string" } },
        "required" => [] }
    end

    it "accepts the string form of a number/integer/boolean" do
      expect(violation({ qty: "2", price: "9.90", flag: "true" }, schema: scalars)).to be_nil
    end

    it "accepts a number where a string is declared (it stringifies losslessly)" do
      expect(violation({ note: 42 }, schema: scalars)).to be_nil
    end

    it "still rejects a non-numeric string for a number" do
      expect(violation({ price: "grátis" }, schema: scalars)).to match(/price: expected number, got a string/)
    end

    it "still rejects a float for an integer" do
      expect(violation({ qty: 1.5 }, schema: scalars)).to match(/qty: expected integer/)
    end

    it "rejects an object where any scalar is declared" do
      expect(violation({ note: { "a" => 1 } }, schema: scalars)).to match(/note: expected string, got an object/)
    end
  end

  describe "enum" do
    let(:enum_schema) do
      { "type" => "object", "properties" => { "agent" => { "type" => "string", "enum" => %w[bia support] } },
        "required" => [] }
    end

    it "accepts a member and rejects a non-member, naming the options" do
      expect(violation({ agent: "bia" }, schema: enum_schema)).to be_nil
      expect(violation({ agent: "ceo" }, schema: enum_schema)).to match(%r{"ceo" is not one of bia/support})
    end
  end

  describe "list size" do
    let(:bounded) do
      { "type" => "object",
        "properties" => { "pairs" => { "type" => "array", "items" => { "type" => "string" },
                                       "minItems" => 1, "maxItems" => 3 } },
        "required" => [] }
    end

    it "catches an empty list where the schema asks for at least one" do
      expect(violation({ pairs: [] }, schema: bounded)).to match(/pairs: needs at least 1 item\(s\), got 0/)
    end

    it "catches a list over the declared maximum" do
      expect(violation({ pairs: %w[a b c d] }, schema: bounded)).to match(/at most 3 item\(s\), got 4/)
    end

    it "passes a list within bounds" do
      expect(violation({ pairs: %w[a b] }, schema: bounded)).to be_nil
    end
  end

  it "is a no-op for a tool with no declared parameters" do
    empty = { "type" => "object", "properties" => {}, "required" => [] }
    expect(violation({ whatever: 1 }, schema: empty)).to be_nil
  end

  describe "violation_output (— the evidence RESULT shape)" do
    let(:spec) { Insika::Evidence::Spec.parse({ "kind" => "products" }) }

    it "nil when the raw carries a well-formed items list" do
      expect(described_class.violation_output(spec, { "items" => [{ "id" => "A", "line" => "x" }] }))
        .to be_nil
    end

    it "nil for a well-formed list / a nil spec" do
      expect(described_class.violation_output(nil, { "items" => [] })).to be_nil
    end

    it "a raw body that is NOT an object is a violation (never a silent empty items)" do
      expect(described_class.violation_output(spec, [])).to eq("evidence: result must be an object")
      expect(described_class.violation_output(spec, "text")).to eq("evidence: result must be an object")
      expect(described_class.violation_output(spec, nil)).to eq("evidence: result must be an object")
    end

    it "missing items path -> message" do
      expect(described_class.violation_output(spec, {})).to eq("evidence: items is missing")
    end

    it "items not a list -> message" do
      expect(described_class.violation_output(spec, { "items" => { "id" => "A" } }))
        .to eq("evidence: items must be a list")
    end

    it "an item without id or line -> message naming the index" do
      expect(described_class.violation_output(spec, { "items" => [{ "id" => "A", "line" => "x" },
                                                                 { "id" => "B" }] }))
        .to eq("evidence: items[1] must be {id, line}")
      expect(described_class.violation_output(spec, { "items" => [{ "line" => "x" }] }))
        .to match(/items\[0\]/)
    end

    it "digs the declared non-default path" do
      custom = Insika::Evidence::Spec.parse({ "kind" => "products", "items" => "results" })
      expect(described_class.violation_output(custom, { "results" => [{ "id" => "A", "line" => "x" }] }))
        .to be_nil
      expect(described_class.violation_output(custom, {})).to eq("evidence: items is missing")
    end
  end
end
