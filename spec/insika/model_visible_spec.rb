# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::ModelVisible do
  # A minimal chat double with the three readers (and the degraded shapes).
  let(:tool) do
    Struct.new(:name, :description, :parameters_schema).new("search_products", "search the catalog",
                                                     { "type" => "object" })
  end
  let(:chat) do
    Struct.new(:instructions, :tools, :messages).new(
      "the system text",
      [tool],
      [{ "role" => "user", "content" => "oi" }]
    )
  end

  describe ".capture" do
    it "reads system messages and the tool map from a real RubyLLM chat" do
      real = RubyLLM.context { |config| config.deepseek_api_key = "offline" }
                    .chat(model: "deepseek-chat", provider: :deepseek, assume_model_exists: true)
      real.with_instructions("Stable", cache_until_here: true).with_instructions("Volatile", append: true)
      real.with_tools(Class.new(RubyLLM::Tool) do
        def name = "lookup"
        parameter :query, description: "Search text"
        def execute(query:) = query
      end.new)

      captured = described_class.capture(real)

      expect(captured.instructions).to eq("Stable\n\nVolatile")
      expect(captured.tools.first).to include("name" => "lookup")
      expect(captured.tools.first.dig("parameters", "properties", "query", "type")).to eq("string")
    end

    it "records the three model-visible parts exactly as the provider serializes them" do
      mv = described_class.capture(chat)
      expect(mv.instructions).to eq("the system text")
      expect(mv.tools).to eq([{ "name" => "search_products", "description" => "search the catalog",
                                "parameters" => { "type" => "object" } }])
      expect(mv.messages).to eq([{ "role" => "user", "content" => "oi" }])
    end

    it "degrades a chat missing a reader to nil/[] (never raises)" do
      mv = described_class.capture(Object.new)
      expect(mv.instructions).to be_nil
      expect(mv.tools).to eq([])
      expect(mv.messages).to eq([])
    end
  end

  describe ".tool_schema" do
    it "reads name/description/parameters_schema off a tool" do
      tool = Struct.new(:name, :description, :parameters_schema).new("t", "desc", { "type" => "object" })
      expect(described_class.tool_schema(tool)).to eq("name" => "t", "description" => "desc",
                                                      "parameters" => { "type" => "object" })
    end

    it "falls back to #schema when the tool answers parameters via schema" do
      tool = Struct.new(:name, :description, :schema).new("t", "desc", { "type" => "object" })
      expect(described_class.tool_schema(tool)["parameters"]).to eq("type" => "object")
    end

    it "a tool answering none of the readers degrades to nil, never raises" do
      expect(described_class.tool_schema(Object.new)).to eq({})
    end
  end

  describe "the store round-trip" do
    it "to_h is JSON-safe (string keys) and from_h restores the value" do
      mv = described_class.capture(chat)
      h = mv.to_h
      expect(h).to eq("instructions" => "the system text",
                      "tools" => [{ "name" => "search_products", "description" => "search the catalog",
                                    "parameters" => { "type" => "object" } }],
                      "messages" => [{ "role" => "user", "content" => "oi" }])
      expect(described_class.from_h(h)).to eq(mv)
    end

    it "from_h tolerates nil (a missing record)" do
      expect(described_class.from_h(nil)).to eq(described_class.new(instructions: nil, tools: [], messages: []))
    end
  end
end
