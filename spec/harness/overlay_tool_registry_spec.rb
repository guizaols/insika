# frozen_string_literal: true

require "spec_helper"

# Fase 5 Etapa B: overlay que compõe tools de código + tools por dados.
RSpec.describe Harness::OverlayToolRegistry do
  # tool de código fake (o overlay só precisa de name/description via factory).
  FakeCodeTool = Struct.new(:name, :description)

  let(:base) do
    r = Harness::ToolRegistry.new
    r.register("menu", plugin: "code", side_effect: true) { FakeCodeTool.new("menu", "cardápio") }
    r.register("calc", plugin: "code") { FakeCodeTool.new("calc", "calcula") }
    r
  end

  let(:store) { Harness::ToolStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:http) { Object.new } # nunca chamado nos testes de resolução

  subject(:overlay) { described_class.new(base: base, tool_store: store, http: http) }

  def def_attrs(name:, method: "GET", **over)
    { name: name, description: "d #{name}",
      parameters: [{ name: "x" }],
      request: { method: method, url: "https://a.test/{{x}}" } }.merge(over)
  end

  describe "paridade (NF1): store vazio ⇒ idêntico à base" do
    it "entries/names/resolve/side_effect batem com a base pura" do
      expect(overlay.names).to eq(base.names)
      expect(overlay.entries.map(&:name)).to eq(base.entries.map(&:name))
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect(overlay.side_effect?("menu")).to be(true)
      expect(overlay.side_effect?("calc")).to be(false)
    end
  end

  describe "com data-tools no store" do
    before do
      store.write(def_attrs(name: "cep"))                 # GET -> side_effect false
      store.write(def_attrs(name: "cria", method: "POST")) # POST -> side_effect true
      overlay.reload
    end

    it "entries/names unem base + dinâmicas" do
      expect(overlay.names).to contain_exactly("menu", "calc", "cep", "cria")
    end

    it "resolve de data-tool -> DataDefinedTool; código continua código" do
      expect(overlay.resolve("cep")).to be_a(Harness::Tools::DataDefinedTool)
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect { overlay.resolve("inexistente") }.to raise_error(Harness::NotFoundError)
    end

    it "side_effect? deriva do método da data-tool" do
      expect(overlay.side_effect?("cep")).to be(false)
      expect(overlay.side_effect?("cria")).to be(true)
    end

    it "code_tool? distingue base de dinâmica" do
      expect(overlay.code_tool?("menu")).to be(true)
      expect(overlay.code_tool?("cep")).to be(false)
    end
  end

  describe "colisão: base (código) SEMPRE vence (R3)" do
    before do
      store.write(def_attrs(name: "menu")) # colide com a tool de código
      overlay.reload
    end

    it "não duplica o nome; resolve devolve a de código, não a data-tool" do
      expect(overlay.names.count("menu")).to eq(1)
      expect(overlay.entries.map(&:name).count("menu")).to eq(1)
      expect(overlay.resolve("menu")).to be_a(FakeCodeTool)
      expect(overlay.side_effect?("menu")).to be(true) # metadado da base
    end
  end

  describe "reload é hot (F5)" do
    it "uma data-tool nova só aparece após reload (índice memoizado)" do
      overlay.names # força o snapshot inicial (memoiza o índice dinâmico)
      store.write(def_attrs(name: "novo"))
      expect(overlay.names).not_to include("novo") # ainda no índice antigo
      overlay.reload
      expect(overlay.names).to include("novo")
    end
  end

  it "definição corrompida no store é ignorada (não derruba o registry)" do
    cs = Harness::ConfigStore.new(store: Harness::Stores::Memory.new)
    cs.put("tools", "ruim", { "definition" => { "name" => "Bad Name", "description" => "x" } })
    ov = described_class.new(base: base, tool_store: Harness::ToolStore.new(config_store: cs), http: http)
    expect { ov.names }.not_to raise_error
    expect(ov.names).to eq(base.names)
  end
end
