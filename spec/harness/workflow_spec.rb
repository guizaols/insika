# frozen_string_literal: true

require "spec_helper"

# Item 22 / §4.4 — the workflow I/O contract: the built-in JSON Schema instance
# validator (Schema) and the Definition that enforces it at the edges.
RSpec.describe Harness::Workflow do
  describe Harness::Workflow::Schema do
    def schema(hash) = described_class.new(hash)

    it "accepts a conforming object and reports success with no errors" do
      s = schema("type" => "object",
                 "properties" => { "q" => { "type" => "string" }, "n" => { "type" => "integer" } },
                 "required" => ["q"])
      result = s.call("q" => "hi", "n" => 3)
      expect(result.success?).to be(true)
      expect(result.errors).to be_empty
    end

    it "flags a missing required field" do
      s = schema("type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"])
      result = s.call({})
      expect(result.success?).to be(false)
      expect(result.errors).to eq("q" => ["is required"])
    end

    it "flags a top-level type mismatch with (root)" do
      expect(schema("type" => "object").call("not a hash").errors).to eq("(root)" => ["must be object, got string"])
    end

    it "type-checks a present property (integer is not boolean, boolean is not number)" do
      s = schema("type" => "object", "properties" => { "n" => { "type" => "integer" }, "b" => { "type" => "boolean" } })
      expect(s.call("n" => true, "b" => 1).errors)
        .to eq("n" => ["must be integer, got boolean"], "b" => ["must be boolean, got integer"])
    end

    it "recurses into nested objects and arrays with a dotted path" do
      s = schema(
        "type" => "object",
        "properties" => {
          "user" => { "type" => "object", "properties" => { "age" => { "type" => "integer" } }, "required" => ["age"] },
          "tags" => { "type" => "array", "items" => { "type" => "string" } }
        }
      )
      result = s.call("user" => { "age" => "old" }, "tags" => %w[a b] << 3)
      expect(result.errors).to eq("user.age" => ["must be integer, got string"], "tags.2" => ["must be string, got integer"])
    end

    it "enforces enum membership" do
      s = schema("type" => "object", "properties" => { "status" => { "type" => "string", "enum" => %w[open closed] } })
      expect(s.call("status" => "open").success?).to be(true)
      expect(s.call("status" => "weird").errors).to eq("status" => [%(must be one of ["open", "closed"])])
    end

    it "is permissive on unknown keys (additionalProperties default)" do
      s = schema("type" => "object", "properties" => { "q" => { "type" => "string" } })
      expect(s.call("q" => "x", "extra" => 99).success?).to be(true)
    end

    it "accepts symbol-keyed instances too (required + property check)" do
      s = schema("type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"])
      expect(s.call(q: "hi").success?).to be(true)
      expect(s.call(q: 1).errors).to eq("q" => ["must be string, got integer"])
    end

    describe ".coerce" do
      it "nil -> nil; a Hash -> a Schema; a #call-able validator -> itself" do
        validator = ->(_v) {}
        expect(described_class.coerce(nil)).to be_nil
        expect(described_class.coerce("type" => "object")).to be_a(described_class)
        expect(described_class.coerce(validator)).to be(validator)
      end
    end

    it "rejects a non-Hash, non-callable schema at construction" do
      expect { described_class.new("nope") }.to raise_error(Harness::ValidationError)
    end
  end

  describe Harness::Workflow::Definition do
    def definition(**over)
      described_class.new(
        **{ name: "flow", description: nil, input_schema: nil, output_schema: nil,
            factory: -> { ->(input, context:, tools:) { input } } }.merge(over)
      )
    end

    it "validate_input! is a no-op without a schema" do
      expect { definition.validate_input!("anything") }.not_to raise_error
    end

    it "validate_input! raises WorkflowSchemaError(phase: :input) with the field detail" do
      d = definition(input_schema: Harness::Workflow::Schema.new(
        "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"]
      ))
      expect { d.validate_input!({}) }.to raise_error(Harness::WorkflowSchemaError) do |e|
        expect(e.phase).to eq(:input)
        expect(e.errors).to eq("q" => ["is required"])
        expect(e.message).to include("q: is required")
      end
    end

    it "validate_output! raises WorkflowSchemaError(phase: :output)" do
      d = definition(output_schema: Harness::Workflow::Schema.new(
        "type" => "object", "properties" => { "ok" => { "type" => "boolean" } }, "required" => ["ok"]
      ))
      expect { d.validate_output!({}) }.to raise_error(Harness::WorkflowSchemaError) { |e| expect(e.phase).to eq(:output) }
    end

    it "works with a duck-typed (dry-schema-compatible) validator and normalizes #errors.to_h" do
      message_set = Object.new
      def message_set.to_h = { "q" => ["is missing"] }
      dry_like = Object.new
      dry_like.define_singleton_method(:call) do |_value|
        result = Object.new
        result.define_singleton_method(:success?) { false }
        result.define_singleton_method(:errors) { message_set }
        result
      end
      d = definition(input_schema: dry_like)
      expect { d.validate_input!({}) }.to raise_error(Harness::WorkflowSchemaError) { |e| expect(e.errors).to eq("q" => ["is missing"]) }
    end

    it "#call resolves the factory lazily and invokes the orchestrator" do
      seen = {}
      d = definition(factory: -> { ->(input, context:, tools:) { seen.merge!(input: input, context: context, tools: tools); "out" } })
      expect(d.call({ "a" => 1 }, context: :ctx, tools: [:t])).to eq("out")
      expect(seen).to eq(input: { "a" => 1 }, context: :ctx, tools: [:t])
    end

    it "#catalog_entry exposes name/description and the schema view (Hash vs opaque vs nil)" do
      d = definition(
        description: "does a thing",
        input_schema: Harness::Workflow::Schema.new("type" => "object"),
        output_schema: ->(_v) {} # opaque validator
      )
      entry = d.catalog_entry
      expect(entry["name"]).to eq("flow")
      expect(entry["description"]).to eq("does a thing")
      expect(entry["input_schema"]).to eq("type" => "object")
      expect(entry["output_schema"]).to eq("opaque")
    end
  end
end
