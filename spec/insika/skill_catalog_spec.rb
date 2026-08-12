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

  describe "companions frontmatter" do
    it "parses a YAML list and a comma-separated string, defaulting to []" do
      path = File.join(@root, "mapa")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"),
                 "---\nname: mapa\ndescription: d\ncompanions:\n  - query-rules\n  - formato\n---\nbody\n")
      lenient = File.join(@root, "outro")
      FileUtils.mkdir_p(lenient)
      File.write(File.join(lenient, "SKILL.md"),
                 "---\nname: outro\ndescription: d\ncompanions: query-rules, formato\n---\nbody\n")
      write_skill(@root, "sozinha", name: "sozinha")

      cat = described_class.new(@root)

      expect(cat.find("mapa").companions).to eq(%w[query-rules formato])
      expect(cat.find("outro").companions).to eq(%w[query-rules formato])
      expect(cat.find("sozinha").companions).to eq([])
    end
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

  # Eagerness is the AGENT's decision (profile.skills_eager), never the skill's:
  # a shared skill sits in several allowlists, and a frontmatter flag forced one
  # decision onto all of them.
  describe "the eager/lazy split" do
    def write_raw(name, frontmatter)
      path = File.join(@root, name)
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"), "---\nname: #{name}\n#{frontmatter}\n---\nbody\n")
    end

    def profile(**over) = Insika::AgentProfile.build(id: "a", model: "m", **over)

    before do
      write_skill(@root, "formato", name: "formato")
      write_skill(@root, "cardapio", name: "cardapio")
    end

    let(:cat) { described_class.new(@root) }

    it "nil (the default) -> nothing eager, everything lazy" do
      expect(cat.eager_for(profile)).to eq([])
      expect(cat.lazy_for(profile).map(&:name)).to contain_exactly("cardapio", "formato")
    end

    it "false -> nothing eager (an operator who turned it off)" do
      expect(cat.eager_for(profile(skills_eager: false))).to eq([])
    end

    it "true -> every allowed skill eager, leaving nothing lazy" do
      blanket = profile(skills_eager: true)

      expect(cat.eager_for(blanket).map(&:name)).to contain_exactly("cardapio", "formato")
      expect(cat.lazy_for(blanket)).to eq([])
    end

    it "[names] -> exactly those, the rest stays lazy" do
      named = profile(skills_eager: ["formato"])

      expect(cat.eager_for(named).map(&:name)).to eq(["formato"])
      expect(cat.lazy_for(named).map(&:name)).to eq(["cardapio"])
    end

    it "[] -> nothing eager (an empty list is not `all`, unlike Allowlist)" do
      expect(cat.eager_for(profile(skills_eager: []))).to eq([])
    end

    it "tolerates the blanket switch as the string a form round-trip produces" do
      %w[true 1 yes on].each do |raw|
        expect(cat.eager_for(profile(skills_eager: raw)).length).to eq(2)
      end
    end

    it "the split respects the agent allowlist" do
      only_cardapio = profile(skills: ["cardapio"], skills_eager: ["formato"])

      expect(cat.eager_for(only_cardapio)).to eq([])
      expect(cat.lazy_for(only_cardapio).map(&:name)).to eq(["cardapio"])
    end

    it "the frontmatter `eager:` key is dead — parsed away, never honored" do
      write_raw("legado", "description: d\neager: true")

      expect(cat.find("legado")).not_to respond_to(:eager)
      expect(cat.eager_for(profile)).to eq([])
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

    # THE ROUTING TABLE, GENERATED. What made activation reliable on the pilot was a
    # hand-written file listing each skill with its trigger phrases — and nothing
    # checked it against the catalog, so a skill created at 11:28 was invisible to a
    # table written the day before, and the model obeyed the table.
    it "renders each skill's triggers, so the table cannot disagree with the catalog" do
      path = File.join(@root, "presente")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "SKILL.md"),
                 "---\nname: presente\ndescription: d\ntriggers: [presente, aniversario]\n---\nbody\n")
      write_skill(@root, "cardapio", name: "cardapio")
      catalog = described_class.new(@root)

      out = catalog.format_for_prompt(catalog.all)

      expect(out).to include('<skill name="presente" when="presente; aniversario">')
      # a skill with no triggers carries no `when` — nothing to route on, no noise
      expect(out).to include('<skill name="cardapio">')
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

  # The precedence chain gains a dimension: (agent, name) in the agent scope, then
  # `name` in the shared one. The pilot's live consequence of not having it: three
  # skills shared between two stores, each naming Natura in its text, served to the
  # Cacau Show agent as its own policy.
  describe "per-agent resolution" do
    let(:store) { Insika::SkillStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
    def skill_md(name, body) = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"
    def profile(id, **over) = Insika::AgentProfile.build(id: id, model: "m", **over)

    it "an override wins for its agent and changes nothing for anyone else" do
      store.write("escalation", skill_md("escalation", "na Natura, devolucao em 7 dias"))
      store.write("escalation", skill_md("escalation", "na Cacau Show, troca na loja"), agent: "cacau")

      cat = described_class.new(@root, store: store)

      expect(cat.find("escalation", agent: "cacau").body).to include("Cacau Show")
      expect(cat.find("escalation", agent: "natura").body).to include("na Natura")
      expect(cat.find("escalation").body).to include("na Natura")
    end

    it "a shared skill stays shared: the override is one more record, not a fork" do
      store.write("escalation", skill_md("escalation", "shared"))
      store.write("escalation", skill_md("escalation", "mine"), agent: "cacau")

      cat = described_class.new(@root, store: store)

      # ONE name in both catalogs — the allowlist, the level-1 list and load_skill all
      # keep saying `escalation`; only the body differs.
      expect(cat.all(agent: "cacau").map(&:name)).to eq(["escalation"])
      expect(cat.all.map(&:name)).to eq(["escalation"])
    end

    it "an agent-private skill is invisible to every other agent" do
      store.write("only-cacau", skill_md("only-cacau", "b"), agent: "cacau")

      cat = described_class.new(@root, store: store)

      expect(cat.all(agent: "cacau").map(&:name)).to eq(["only-cacau"])
      expect(cat.all).to eq([])
      expect(cat.find("only-cacau")).to be_nil
      expect(cat.find("only-cacau", agent: "natura")).to be_nil
    end

    # THE bug the agent scope exists to fix: an override keeps saying the bare shared
    # name inside (it IS the same skill, specialized), so indexing by the parsed
    # frontmatter would clobber the shared record globally.
    it "the STORE POSITION is the identity, not the frontmatter name" do
      store.write("escalation", skill_md("escalation", "shared"))
      store.write("escalation", skill_md("escalation", "mine"), agent: "cacau")

      cat = described_class.new(@root, store: store)

      expect(cat.find("escalation").body).to eq("shared")
      expect(cat.find("escalation", agent: "cacau").name).to eq("escalation")
    end

    it "a store record whose key and frontmatter name disagree resolves by the KEY" do
      store.write("gift-concierge", skill_md("presente", "b"))

      cat = described_class.new(@root, store: store)

      expect(cat.find("gift-concierge")&.name).to eq("gift-concierge")
      expect(cat.find("presente")).to be_nil
    end

    it "eager_for/lazy_for resolve through the agent's own scope" do
      store.write("esc", skill_md("esc", "shared"))
      store.write("esc", skill_md("esc", "mine"), agent: "cacau")

      cat = described_class.new(@root, store: store)

      expect(cat.eager_for(profile("cacau", skills_eager: ["esc"])).first.body).to eq("mine")
      expect(cat.lazy_for(profile("natura")).first.body).to eq("shared")
    end

    it "a store without the agent dimension (an older one) falls through to shared" do
      legacy = Class.new do
        def all(*) = { "esc" => "---\nname: esc\ndescription: d\n---\nshared\n" }
      end.new

      cat = described_class.new(@root, store: legacy)

      expect(cat.find("esc", agent: "cacau").body).to eq("shared")
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
