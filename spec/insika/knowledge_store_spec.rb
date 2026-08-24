# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# LEARNED concepts (concept markdown in the durable Store), scoped per agent
# and optional tenant.
RSpec.describe Insika::KnowledgeStore do
  subject(:store) { described_class.new(store: Insika::Stores::Memory.new) }

  def concept_md(name, body = "body") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  it "write/get round-trip; names/all list the agent's concepts" do
    store.write("acme", "cep-13", concept_md("cep-13"))
    store.write("acme", "frete-gratis", concept_md("frete-gratis"))

    expect(store.get("acme", "cep-13")).to eq(concept_md("cep-13"))
    expect(store.names("acme")).to eq(%w[cep-13 frete-gratis]) # lexicographic
    expect(store.all("acme").keys).to contain_exactly("cep-13", "frete-gratis")
  end

  it "meta -> {content:, updated_at:} without needing a parse; nil for a missing concept" do
    store.write("acme", "cep-13", concept_md("cep-13"))
    meta = store.meta("acme", "cep-13")

    expect(meta["content"]).to eq(concept_md("cep-13"))
    expect { Time.iso8601(meta["updated_at"]) }.not_to raise_error
    expect(store.meta("acme", "missing")).to be_nil
  end

  it "meta always reflects the latest write, matching get" do
    store.write("acme", "cep-13", concept_md("cep-13", "v1"))
    store.write("acme", "cep-13", concept_md("cep-13", "v2"))

    expect(store.meta("acme", "cep-13")["content"]).to eq(store.get("acme", "cep-13"))
    expect(store.meta("acme", "cep-13")["content"]).to eq(concept_md("cep-13", "v2"))
  end

  it "overwriting pushes the old version into bounded history" do
    store.write("acme", "cep-13", concept_md("cep-13", "v1"))
    store.write("acme", "cep-13", concept_md("cep-13", "v2"))

    expect(store.versions("acme", "cep-13").map { |h| h["content"] }).to eq([concept_md("cep-13", "v1")])
    expect(store.get("acme", "cep-13")).to eq(concept_md("cep-13", "v2"))
  end

  it "export_dir writes one <name>.md per concept, byte for byte (a dump, not a converter)" do
    store.write("acme", "cep-13", concept_md("cep-13", "v1"))
    store.write("acme", "frete-gratis", concept_md("frete-gratis", "v2"))

    Dir.mktmpdir do |dir|
      paths = store.export_dir("acme", dir)

      expect(paths.map { |p| File.basename(p) }).to contain_exactly("cep-13.md", "frete-gratis.md")
      expect(File.read(File.join(dir, "cep-13.md"))).to eq(concept_md("cep-13", "v1"))
      expect(File.read(File.join(dir, "frete-gratis.md"))).to eq(concept_md("frete-gratis", "v2"))
    end
  end

  it "export_dir creates the destination directory, and is idempotent (safe to re-run)" do
    store.write("acme", "cep-13", concept_md("cep-13"))

    Dir.mktmpdir do |base|
      dir = File.join(base, "nested", "export")
      store.export_dir("acme", dir)
      expect { store.export_dir("acme", dir) }.not_to raise_error
      expect(File.read(File.join(dir, "cep-13.md"))).to eq(concept_md("cep-13"))
    end
  end

  it "export_dir scopes by agent and tenant, and returns [] for an empty scope" do
    store.write("acme", "cep-13", concept_md("cep-13"))
    store.write("acme", "loja-a-only", concept_md("loja-a-only"), tenant: "loja-a")

    Dir.mktmpdir do |dir|
      expect(store.export_dir("zeta", dir)).to eq([])
      expect(store.export_dir("acme", dir).map { |p| File.basename(p) }).to eq(["cep-13.md"])
    end

    Dir.mktmpdir do |dir|
      paths = store.export_dir("acme", dir, tenant: "loja-a")
      expect(paths.map { |p| File.basename(p) }).to eq(["loja-a-only.md"])
    end
  end

  it "delete -> bool; restore reverts to an old version" do
    store.write("acme", "cep-13", concept_md("cep-13", "v1"))
    store.write("acme", "cep-13", concept_md("cep-13", "v2"))
    store.restore("acme", "cep-13", 0)

    expect(store.get("acme", "cep-13")).to eq(concept_md("cep-13", "v1"))
    expect(store.delete("acme", "cep-13")).to be(true)
    expect(store.delete("acme", "cep-13")).to be(false)
  end

  it "restore raises for a missing concept or an out-of-range version" do
    expect { store.restore("acme", "missing", 0) }.to raise_error(Insika::NotFoundError, /not found/)

    store.write("acme", "cep-13", concept_md("cep-13"))
    expect { store.restore("acme", "cep-13", 5) }.to raise_error(Insika::ValidationError, /does not exist/)
  end

  describe "scoping" do
    it "one agent's concepts are invisible to another" do
      store.write("acme", "cep-13", concept_md("cep-13", "acme's"))
      store.write("zeta", "cep-13", concept_md("cep-13", "zeta's"))

      expect(store.get("acme", "cep-13")).to eq(concept_md("cep-13", "acme's"))
      expect(store.get("zeta", "cep-13")).to eq(concept_md("cep-13", "zeta's"))
      expect(store.names("acme")).to eq(["cep-13"])
    end

    it "an explicit tenant is a second cell under the same agent, isolated from the default scope" do
      store.write("acme", "cep-13", concept_md("cep-13", "default"))
      store.write("acme", "cep-13", concept_md("cep-13", "loja-a"), tenant: "loja-a")

      expect(store.get("acme", "cep-13")).to eq(concept_md("cep-13", "default"))
      expect(store.get("acme", "cep-13", tenant: "loja-a")).to eq(concept_md("cep-13", "loja-a"))
      expect(store.names("acme", tenant: "loja-a")).to eq(["cep-13"])
    end
  end
end
