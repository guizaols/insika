# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::WorkflowRegistry do
  subject(:registry) { described_class.new }

  it "resolves a callable registered via a lambda" do
    registry.register("w", ->(input, context:, tools:) { [input, context, tools] })
    wf = registry.resolve("w")
    expect(wf.call("in", context: :ctx, tools: [])).to eq(["in", :ctx, []])
  end

  it "resolves a callable registered via a factory block" do
    registry.register("w") { ->(input, **) { "handled:#{input}" } }
    expect(registry.resolve("w").call("x")).to eq("handled:x")
  end

  it "inherits duplicate handling (first wins) and NotFound from the generic base" do
    registry.register("w", -> {})
    expect { registry.register("w", -> {}) }.to output.to_stderr
    expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
  end

  describe "#definition (item 22 / §4.4)" do
    it "bundles the factory with the schema/description metadata WITHOUT resolving it" do
      resolved = false
      registry.register("w", input_schema: { "type" => "object" }, description: "d") do
        resolved = true
        ->(input, **) { input }
      end

      d = registry.definition("w")
      expect(resolved).to be(false) # definition never touches the factory
      expect(d.name).to eq("w")
      expect(d.description).to eq("d")
      expect(d.input_schema).to be_a(Harness::Workflow::Schema)
      expect(d.output_schema).to be_nil
    end

    it "definition NotFound for an unregistered name" do
      expect { registry.definition("nope") }.to raise_error(Harness::NotFoundError)
    end
  end

  describe "#catalog" do
    it "lists every workflow with its name/description and I/O schema view" do
      registry.register("a", ->(*, **) {}, description: "first",
                                           input_schema: { "type" => "object", "properties" => { "q" => { "type" => "string" } } })
      registry.register("b", ->(*, **) {})

      cat = registry.catalog
      expect(cat.map { |e| e["name"] }).to contain_exactly("a", "b")
      a = cat.find { |e| e["name"] == "a" }
      expect(a["description"]).to eq("first")
      expect(a["input_schema"]).to include("type" => "object")
      expect(cat.find { |e| e["name"] == "b" }["input_schema"]).to be_nil
    end
  end
end
