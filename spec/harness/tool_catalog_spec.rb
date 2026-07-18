# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::ToolCatalog do
  # Double that only responds to :description — without inheriting RubyLLM::Tool (duck typing).
  FakeTool = Struct.new(:description)

  let(:registry) { Harness::ToolRegistry.new }

  def catalog = described_class.new(tool_registry: registry)

  describe "#all" do
    it "one Entry(name, description) per registry entry, in registry order" do
      registry.register("send_email") { FakeTool.new("Sends an e-mail to the recipient") }
      registry.register("fetch_page") { FakeTool.new("Downloads a web page") }
      entries = catalog.all
      expect(entries.map(&:name)).to eq(%w[send_email fetch_page])
      expect(entries.first.description).to eq("Sends an e-mail to the recipient")
    end

    it "reads the description via a factory instance (duck typing)" do
      registry.register("t") { FakeTool.new("desc") }
      expect(catalog.all.first.description).to eq("desc")
    end

    it "description nil -> '' (never nil)" do
      registry.register("t") { FakeTool.new(nil) }
      expect(catalog.all.first.description).to eq("")
    end

    it "empty catalog -> []" do
      expect(catalog.all).to eq([])
    end
  end

  describe "#subset" do
    before do
      registry.register("a") { FakeTool.new("aa") }
      registry.register("b") { FakeTool.new("bb") }
    end

    it "returns only the requested entries" do
      expect(catalog.subset(["a"]).map(&:name)).to eq(["a"])
    end

    it "ignores unknown names without error" do
      expect(catalog.subset(%w[a inexistente]).map(&:name)).to eq(["a"])
    end

    it "subset([]) / subset(nil) -> []" do
      expect(catalog.subset([])).to eq([])
      expect(catalog.subset(nil)).to eq([])
    end
  end

  describe "#search" do
    before do
      registry.register("send_email") { FakeTool.new("Sends a message to the recipient") }
      registry.register("create_invoice") { FakeTool.new("Generates a PDF invoice") }
    end

    it "matches by name" do
      expect(catalog.search("email").map(&:name)).to eq(["send_email"])
    end

    it "matches by description only" do
      expect(catalog.search("recipient").map(&:name)).to eq(["send_email"])
    end

    it "empty / nil / whitespace-only query -> []" do
      expect(catalog.search("")).to eq([])
      expect(catalog.search(nil)).to eq([])
      expect(catalog.search("   ")).to eq([])
    end

    it "within: restricts the universe (a tool outside the slice does not appear)" do
      expect(catalog.search("invoice", within: ["send_email"])).to eq([])
    end

    it "ranking: a name match (weight 2) comes before a description-only match (weight 1)" do
      registry.register("report") { FakeTool.new("faz um email resumido") } # 'email' in the desc
      # 'email' hits the name of send_email (2) and the desc of report (1)
      expect(catalog.search("email").map(&:name)).to eq(%w[send_email report])
    end

    it "a score tie preserves the original order of the universe" do
      reg = Harness::ToolRegistry.new
      reg.register("z_tool") { FakeTool.new("faz xyz") }
      reg.register("a_tool") { FakeTool.new("faz xyz") }
      cat = described_class.new(tool_registry: reg)
      # both hit only the desc ('xyz'), equal score -> registration order (z before a)
      expect(cat.search("xyz").map(&:name)).to eq(%w[z_tool a_tool])
    end
  end

  describe "#format_for_prompt" do
    before { registry.register("send_email") { FakeTool.new("Envia e-mail") } }

    it "includes <available_tools>, name, description and the tool_search instruction" do
      out = catalog.format_for_prompt(catalog.all)
      expect(out).to include("<available_tools>")
      expect(out).to include(%(name="send_email"))
      expect(out).to include("Envia e-mail")
      expect(out).to include("tool_search")
    end

    it "format_for_prompt([]) -> ''" do
      expect(catalog.format_for_prompt([])).to eq("")
    end
  end

  it "lazy: does not instantiate any tool on construction (only on the 1st query)" do
    instantiations = 0
    registry.register("t") { instantiations += 1; FakeTool.new("desc") }
    cat = described_class.new(tool_registry: registry)
    expect(instantiations).to eq(0)  # boot does not touch the tool
    cat.all
    expect(instantiations).to eq(1)  # instantiated on the 1st use
    cat.all
    expect(instantiations).to eq(1)  # memoized — does not reinstantiate
  end

  it "a factory that raises propagates on the 1st use (where the Executor would also catch it)" do
    registry.register("boom") { raise "registro quebrado" }
    cat = described_class.new(tool_registry: registry)
    expect { cat.all }.to raise_error(/registro quebrado/)
  end
end
