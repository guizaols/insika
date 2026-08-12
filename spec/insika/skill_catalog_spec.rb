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

  describe "triggers frontmatter" do
    it "parses a YAML list" do
      path = File.join(@root, "perfume")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"),
                 "---\nname: perfume\ndescription: d\ntriggers:\n  - perfume dia a dia\n  - cor do frasco\n---\nbody\n")

      expect(described_class.new(@root).find("perfume").triggers).to eq(["perfume dia a dia", "cor do frasco"])
    end

    it "parses a comma-separated string (lenient path) and defaults to []" do
      path = File.join(@root, "perfume")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"),
                 "---\nname: perfume\ndescription: d\ntriggers: perfume dia a dia, cor do frasco\n---\nbody\n")

      expect(described_class.new(@root).find("perfume").triggers).to eq(["perfume dia a dia", "cor do frasco"])

      write_skill(@root, "sem", name: "sem")
      expect(described_class.new(@root).find("sem").triggers).to eq([])
    end
  end

  describe "eager frontmatter + the eager/lazy split" do
    def write_raw(name, frontmatter)
      path = File.join(@root, name)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\n#{frontmatter}\n---\nbody\n")
    end

    let(:profile) { Insika::AgentProfile.build(id: "a", model: "m") }

    it "reads eager: true, and defaults to false" do
      write_raw("formato", "description: d\neager: true")
      write_skill(@root, "cardapio", name: "cardapio")

      cat = described_class.new(@root)

      expect(cat.find("formato").eager).to be(true)
      expect(cat.find("cardapio").eager).to be(false)
    end

    it "accepts the spellings an operator actually writes" do
      %w[yes 1 on TRUE].each_with_index do |v, i|
        write_raw("s#{i}", "description: d\neager: #{v}")
      end
      write_raw("sem-eager", "description: d\neager: false")

      cat = described_class.new(@root)

      expect((0..3).map { |i| cat.find("s#{i}").eager }).to all(be(true))
      expect(cat.find("sem-eager").eager).to be(false)
    end

    it "splits the allowed set into eager (always) and lazy (load_skill)" do
      write_raw("formato", "description: d\neager: true")
      write_skill(@root, "cardapio", name: "cardapio")

      cat = described_class.new(@root)

      expect(cat.eager_for(profile).map(&:name)).to eq(["formato"])
      expect(cat.lazy_for(profile).map(&:name)).to eq(["cardapio"])
    end

    it "skills_eager on the profile makes every allowed skill eager, leaving nothing lazy" do
      write_skill(@root, "cardapio", name: "cardapio")
      write_skill(@root, "pedido", name: "pedido")
      blanket = Insika::AgentProfile.build(id: "a", model: "m", skills_eager: true)

      cat = described_class.new(@root)

      expect(cat.eager_for(blanket).map(&:name)).to contain_exactly("cardapio", "pedido")
      expect(cat.lazy_for(blanket)).to eq([])
    end

    it "the split respects the agent allowlist" do
      write_raw("formato", "description: d\neager: true")
      write_skill(@root, "cardapio", name: "cardapio")
      only_cardapio = Insika::AgentProfile.build(id: "a", model: "m", skills: ["cardapio"])

      cat = described_class.new(@root)

      expect(cat.eager_for(only_cardapio)).to eq([])
      expect(cat.lazy_for(only_cardapio).map(&:name)).to eq(["cardapio"])
    end
  end

  describe "#effective (allowlist)" do
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

  describe "Store overlay + reload" do
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
