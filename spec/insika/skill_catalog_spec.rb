# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Insika::SkillCatalog do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write_skill(root, dir, name:, description: "desc", body: "complete body")
    path = File.join(root, dir)
    FileUtils.mkdir_p(path)
    frontmatter = name.nil? ? "description: #{description}" : "name: #{name}\ndescription: #{description}"
    File.write(File.join(path, "SKILL.md"), "---\n#{frontmatter}\n---\n#{body}\n")
  end

  describe "#effective (Phase 0 allowlist)" do
    before do
      write_skill(@root, "cardapio", name: "cardapio")
      write_skill(@root, "pedido", name: "pedido")
    end

    it "nil -> all" do
      expect(described_class.new(@root).effective(nil).map(&:name)).to contain_exactly("cardapio", "pedido")
    end

    it "[] -> none" do
      expect(described_class.new(@root).effective([])).to eq([])
    end

    it "[names] -> final subset" do
      expect(described_class.new(@root).effective(["cardapio"]).map(&:name)).to eq(["cardapio"])
    end
  end

  describe "root precedence" do
    it "first root wins for the same skill name" do
      root_a = File.join(@root, "a")
      root_b = File.join(@root, "b")
      write_skill(root_a, "cardapio", name: "cardapio", body: "de A")
      write_skill(root_b, "cardapio", name: "cardapio", body: "de B")

      catalog = described_class.new([root_a, root_b])

      expect(catalog.find("cardapio").body).to eq("de A")
    end
  end

  describe "#format_for_prompt" do
    it "non-empty set generates <available_skills> block" do
      write_skill(@root, "cardapio", name: "cardapio", description: "o cardápio")
      catalog = described_class.new(@root)

      out = catalog.format_for_prompt(catalog.all)

      expect(out).to include("<available_skills>", 'name="cardapio"', "o cardápio", "load_skill")
    end

    it "empty set -> empty string" do
      expect(described_class.new(@root).format_for_prompt([])).to eq("")
    end
  end

  describe "Store overlay + reload (Step C)" do
    let(:store) { Insika::SkillStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
    def skill_md(name, body) = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

    it "skills authored in the Store appear alongside those from disk" do
      write_skill(@root, "cardapio", name: "cardapio", body: "disco")
      store.write("pedido", skill_md("pedido", "do store"))

      catalog = described_class.new(@root, store: store)

      expect(catalog.all.map(&:name)).to contain_exactly("cardapio", "pedido")
      expect(catalog.find("pedido").body).to eq("do store")
    end

    it "Store WINS over disk for the same name (authored > seed)" do
      write_skill(@root, "pedido", name: "pedido", body: "seed do disco")
      store.write("pedido", skill_md("pedido", "editado no studio"))

      catalog = described_class.new(@root, store: store)

      expect(catalog.find("pedido").body).to eq("editado no studio")
    end

    it "reload picks up a skill written to the Store after boot (hot, no restart)" do
      catalog = described_class.new(@root, store: store)
      expect(catalog.find("pedido")).to be_nil

      store.write("pedido", skill_md("pedido", "nova"))
      catalog.reload

      expect(catalog.find("pedido").body).to eq("nova")
    end
  end

  describe "malformed SKILL.md" do
    it "ignores file without frontmatter" do
      path = File.join(@root, "bad")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"), "sem frontmatter aqui")

      expect(described_class.new(@root).all).to eq([])
    end

    it "ignores frontmatter without name" do
      write_skill(@root, "noname", name: nil)

      expect(described_class.new(@root).all).to eq([])
    end
  end
end
