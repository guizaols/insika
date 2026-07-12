# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Harness::SkillCatalog do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write_skill(root, dir, name:, description: "desc", body: "corpo completo")
    path = File.join(root, dir)
    FileUtils.mkdir_p(path)
    frontmatter = name.nil? ? "description: #{description}" : "name: #{name}\ndescription: #{description}"
    File.write(File.join(path, "SKILL.md"), "---\n#{frontmatter}\n---\n#{body}\n")
  end

  describe "#effective (allowlist da Fase 0)" do
    before do
      write_skill(@root, "cardapio", name: "cardapio")
      write_skill(@root, "pedido", name: "pedido")
    end

    it "nil -> todas" do
      expect(described_class.new(@root).effective(nil).map(&:name)).to contain_exactly("cardapio", "pedido")
    end

    it "[] -> nenhuma" do
      expect(described_class.new(@root).effective([])).to eq([])
    end

    it "[names] -> subconjunto final" do
      expect(described_class.new(@root).effective(["cardapio"]).map(&:name)).to eq(["cardapio"])
    end
  end

  describe "precedência de roots" do
    it "primeiro root vence para mesmo nome de skill" do
      root_a = File.join(@root, "a")
      root_b = File.join(@root, "b")
      write_skill(root_a, "cardapio", name: "cardapio", body: "de A")
      write_skill(root_b, "cardapio", name: "cardapio", body: "de B")

      catalog = described_class.new([root_a, root_b])

      expect(catalog.find("cardapio").body).to eq("de A")
    end
  end

  describe "#format_for_prompt" do
    it "conjunto não-vazio gera bloco <available_skills>" do
      write_skill(@root, "cardapio", name: "cardapio", description: "o cardápio")
      catalog = described_class.new(@root)

      out = catalog.format_for_prompt(catalog.all)

      expect(out).to include("<available_skills>", 'name="cardapio"', "o cardápio", "load_skill")
    end

    it "conjunto vazio -> string vazia" do
      expect(described_class.new(@root).format_for_prompt([])).to eq("")
    end
  end

  describe "overlay do Store + reload (Etapa C)" do
    let(:store) { Harness::SkillStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
    def skill_md(name, body) = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

    it "skills autoradas no Store aparecem junto com as de disco" do
      write_skill(@root, "cardapio", name: "cardapio", body: "disco")
      store.write("pedido", skill_md("pedido", "do store"))

      catalog = described_class.new(@root, store: store)

      expect(catalog.all.map(&:name)).to contain_exactly("cardapio", "pedido")
      expect(catalog.find("pedido").body).to eq("do store")
    end

    it "Store VENCE o disco para o mesmo nome (autorado > seed)" do
      write_skill(@root, "pedido", name: "pedido", body: "seed do disco")
      store.write("pedido", skill_md("pedido", "editado no studio"))

      catalog = described_class.new(@root, store: store)

      expect(catalog.find("pedido").body).to eq("editado no studio")
    end

    it "reload pega uma skill gravada no Store depois do boot (hot, sem restart)" do
      catalog = described_class.new(@root, store: store)
      expect(catalog.find("pedido")).to be_nil

      store.write("pedido", skill_md("pedido", "nova"))
      catalog.reload

      expect(catalog.find("pedido").body).to eq("nova")
    end
  end

  describe "SKILL.md malformado" do
    it "ignora arquivo sem frontmatter" do
      path = File.join(@root, "bad")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"), "sem frontmatter aqui")

      expect(described_class.new(@root).all).to eq([])
    end

    it "ignora frontmatter sem name" do
      write_skill(@root, "noname", name: nil)

      expect(described_class.new(@root).all).to eq([])
    end
  end
end
