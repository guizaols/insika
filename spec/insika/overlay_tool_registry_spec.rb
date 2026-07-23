# frozen_string_literal: true

require "spec_helper"

# Phase 5 Step B: overlay that composes code tools + data-driven tools.
RSpec.describe Insika::OverlayToolRegistry do
  # fake code tool (the overlay only needs name/description via factory).
  FakeCodeTool = Struct.new(:name, :description)

  let(:base) do
    r = Insika::ToolRegistry.new
    r.register("menu", plugin: "code", side_effect: true) { FakeCodeTool.new("menu", "cardápio") }
    r.register("calc", plugin: "code") { FakeCodeTool.new("calc", "calcula") }
    r
  end

  let(:store) { Insika::ToolStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:http) { Object.new } # never called in the resolution tests

  subject(:overlay) { described_class.new(base: base, tool_store: store, http: http) }

  def def_attrs(name:, method: "GET", **over)
    { name: name, description: "d #{name}",
      parameters: [{ name: "x" }],
      request: { method: method, url: "https://a.test/{{x}}" } }.merge(over)
  end

  describe "parity (NF1): empty store ⇒ identical to the base" do
    it "entries/names/resolve/side_effect match the pure base" do
      expect(overlay.names).to eq(base.names)
      expect(overlay.entries.map(&:name)).to eq(base.entries.map(&:name))
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect(overlay.side_effect?("menu")).to be(true)
      expect(overlay.side_effect?("calc")).to be(false)
    end
  end

  describe "with data-tools in the store" do
    before do
      store.write(def_attrs(name: "cep"))                 # GET -> side_effect false
      store.write(def_attrs(name: "cria", method: "POST")) # POST -> side_effect true
      overlay.reload
    end

    it "entries/names merge base + dynamic" do
      expect(overlay.names).to contain_exactly("menu", "calc", "cep", "cria")
    end

    it "resolve of data-tool -> DataDefinedTool; code stays code" do
      expect(overlay.resolve("cep")).to be_a(Insika::Tools::DataDefinedTool)
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect { overlay.resolve("inexistente") }.to raise_error(Insika::NotFoundError)
    end

    it "side_effect? derives from the data-tool's method" do
      expect(overlay.side_effect?("cep")).to be(false)
      expect(overlay.side_effect?("cria")).to be(true)
    end

    it "code_tool? distinguishes base from dynamic" do
      expect(overlay.code_tool?("menu")).to be(true)
      expect(overlay.code_tool?("cep")).to be(false)
    end

    # Phase 7/D4/F5 (Step C): the ToolAllowlist policy expands the group via the metadata.
    it "exposes group/tags of the data-tool in the Entry's metadata" do
      store.write(def_attrs(name: "b2b_tool", group: "b2b", tags: ["catalog"]))
      overlay.reload
      entry = overlay.entries.find { |e| e.name == "b2b_tool" }
      expect(entry.metadata[:group]).to eq("b2b")
      expect(entry.metadata[:tags]).to eq(["catalog"])
    end
  end

  describe "collision: base (code) ALWAYS wins (R3)" do
    before do
      store.write(def_attrs(name: "menu")) # collides with the code tool
      overlay.reload
    end

    it "does not duplicate the name; resolve returns the code one, not the data-tool" do
      expect(overlay.names.count("menu")).to eq(1)
      expect(overlay.entries.map(&:name).count("menu")).to eq(1)
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect(overlay.side_effect?("menu")).to be(true) # base metadata
    end
  end

  describe "reload is hot (F5)" do
    it "a new data-tool only appears after reload (memoized index)" do
      overlay.names # forces the initial snapshot (memoizes the dynamic index)
      store.write(def_attrs(name: "novo"))
      expect(overlay.names).not_to include("novo") # still in the old index
      overlay.reload
      expect(overlay.names).to include("novo")
    end
  end

  it "corrupted definition in the store is ignored (does not bring down the registry)" do
    cs = Insika::ConfigStore.new(store: Insika::Stores::Memory.new)
    cs.put("tools", "ruim", { "definition" => { "name" => "Bad Name", "description" => "x" } })
    ov = described_class.new(base: base, tool_store: Insika::ToolStore.new(config_store: cs), http: http)
    expect { ov.names }.not_to raise_error
    expect(ov.names).to eq(base.names)
  end
end
