# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::ToolCatalog do
  # Dublê que só responde a :description — sem herdar RubyLLM::Tool (duck typing).
  FakeTool = Struct.new(:description)

  let(:registry) { Harness::ToolRegistry.new }

  def catalog = described_class.new(tool_registry: registry)

  describe "#all" do
    it "uma Entry(name, description) por entry do registry, na ordem do registry" do
      registry.register("send_email") { FakeTool.new("Envia um e-mail ao destinatário") }
      registry.register("fetch_page") { FakeTool.new("Baixa uma página web") }
      entries = catalog.all
      expect(entries.map(&:name)).to eq(%w[send_email fetch_page])
      expect(entries.first.description).to eq("Envia um e-mail ao destinatário")
    end

    it "lê a description via instância do factory (duck typing)" do
      registry.register("t") { FakeTool.new("desc") }
      expect(catalog.all.first.description).to eq("desc")
    end

    it "description nil -> '' (nunca nil)" do
      registry.register("t") { FakeTool.new(nil) }
      expect(catalog.all.first.description).to eq("")
    end

    it "catálogo vazio -> []" do
      expect(catalog.all).to eq([])
    end
  end

  describe "#subset" do
    before do
      registry.register("a") { FakeTool.new("aa") }
      registry.register("b") { FakeTool.new("bb") }
    end

    it "devolve só as entries pedidas" do
      expect(catalog.subset(["a"]).map(&:name)).to eq(["a"])
    end

    it "ignora nomes desconhecidos sem erro" do
      expect(catalog.subset(%w[a inexistente]).map(&:name)).to eq(["a"])
    end

    it "subset([]) / subset(nil) -> []" do
      expect(catalog.subset([])).to eq([])
      expect(catalog.subset(nil)).to eq([])
    end
  end

  describe "#search" do
    before do
      registry.register("send_email") { FakeTool.new("Envia mensagem ao destinatário") }
      registry.register("create_invoice") { FakeTool.new("Gera uma fatura em PDF") }
    end

    it "casa por name" do
      expect(catalog.search("email").map(&:name)).to eq(["send_email"])
    end

    it "casa só por description" do
      expect(catalog.search("destinatário").map(&:name)).to eq(["send_email"])
    end

    it "query vazia / nil / só espaços -> []" do
      expect(catalog.search("")).to eq([])
      expect(catalog.search(nil)).to eq([])
      expect(catalog.search("   ")).to eq([])
    end

    it "within: restringe o universo (tool fora do recorte não aparece)" do
      expect(catalog.search("fatura", within: ["send_email"])).to eq([])
    end

    it "ranking: match no name (peso 2) vem antes de match só na description (peso 1)" do
      registry.register("report") { FakeTool.new("faz um email resumido") } # 'email' na desc
      # 'email' bate no name de send_email (2) e na desc de report (1)
      expect(catalog.search("email").map(&:name)).to eq(%w[send_email report])
    end

    it "empate de score preserva a ordem original do universo" do
      reg = Harness::ToolRegistry.new
      reg.register("z_tool") { FakeTool.new("faz xyz") }
      reg.register("a_tool") { FakeTool.new("faz xyz") }
      cat = described_class.new(tool_registry: reg)
      # ambas batem só na desc ('xyz'), score igual -> ordem de registro (z antes de a)
      expect(cat.search("xyz").map(&:name)).to eq(%w[z_tool a_tool])
    end
  end

  describe "#format_for_prompt" do
    before { registry.register("send_email") { FakeTool.new("Envia e-mail") } }

    it "inclui <available_tools>, name, description e a instrução tool_search" do
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

  it "factory que levanta propaga na construção (falha alto e cedo)" do
    registry.register("boom") { raise "registro quebrado" }
    expect { described_class.new(tool_registry: registry) }.to raise_error(/registro quebrado/)
  end
end
