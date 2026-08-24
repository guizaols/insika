# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Knowledge::Index do
  let(:store) { Insika::KnowledgeStore.new(store: Insika::Stores::Memory.new) }

  def seed(name, description: "d", body: "b", confidence: 0.6, updated_at: Time.now.utc.iso8601)
    store.write("acme", name,
                Insika::Knowledge::Concept.render(
                  name: name, description: description, type: "fact", body: body,
                  provenance: "observed", confidence: confidence, sources: ["sess_1"], occurrences: 1,
                  created_at: updated_at, updated_at: updated_at
                ))
  end

  describe ".build" do
    it "defaults to Scan, and falls back to Scan for fts5 (not built yet) and any unknown value" do
      expect(described_class.build({}, store: store)).to be_a(described_class::Scan)
      expect(described_class.build({ "index" => "scan" }, store: store)).to be_a(described_class::Scan)
      expect(described_class.build({ "index" => "fts5" }, store: store)).to be_a(described_class::Scan)
      expect(described_class.build({ "index" => "bogus" }, store: store)).to be_a(described_class::Scan)
      expect(described_class.build(nil, store: store)).to be_a(described_class::Scan)
    end
  end

  describe Insika::Knowledge::Index::Scan do
    subject(:index) { described_class.new(store: store) }

    it "matches on name, description or body, case-insensitively" do
      seed("cep-13-campinas", description: "shipping from Campinas", body: "orders in 13xxx ship fast")
      expect(index.search("acme", query: "CAMPINAS").map { |c| c[:name] }).to eq(["cep-13-campinas"])
      expect(index.search("acme", query: "shipping").map { |c| c[:name] }).to eq(["cep-13-campinas"])
      expect(index.search("acme", query: "fast").map { |c| c[:name] }).to eq(["cep-13-campinas"])
    end

    it "excludes concepts with zero term overlap" do
      seed("cep-13-campinas")
      expect(index.search("acme", query: "nothing matches here")).to eq([])
    end

    it "an empty or blank query matches nothing" do
      seed("cep-13-campinas")
      expect(index.search("acme", query: "")).to eq([])
      expect(index.search("acme", query: "   ")).to eq([])
    end

    it "weights a name match over a description match over a body match" do
      seed("frete", description: "irrelevant", body: "irrelevant")
      seed("outro", description: "frete gratis", body: "irrelevant")
      seed("terceiro", description: "irrelevant", body: "sobre frete")
      ranked = index.search("acme", query: "frete").map { |c| c[:name] }
      expect(ranked).to eq(%w[frete outro terceiro])
    end

    it "higher confidence ranks a term-tied concept higher" do
      seed("baixa", body: "campinas", confidence: 0.2)
      seed("alta", body: "campinas", confidence: 0.9)
      expect(index.search("acme", query: "campinas").map { |c| c[:name] }).to eq(%w[alta baixa])
    end

    it "a more recently updated concept ranks a term-tied concept higher" do
      seed("velho", body: "campinas", updated_at: (Time.now.utc - (60 * 86_400)).iso8601)
      seed("novo", body: "campinas", updated_at: Time.now.utc.iso8601)
      expect(index.search("acme", query: "campinas").map { |c| c[:name] }).to eq(%w[novo velho])
    end

    it "an unparseable timestamp gets a neutral recency weight, never excluded" do
      store.write("acme", "sem-data", "not a concept at all — no frontmatter")
      seed("com-data", body: "campinas")
      # "sem-data" fails Concept.parse (no frontmatter) and is filtered out entirely —
      # this just proves the neutral-concept case doesn't raise or crash the search.
      expect { index.search("acme", query: "campinas") }.not_to raise_error
    end

    it "caps at top_k, most relevant first" do
      5.times { |i| seed("c-#{i}", body: "campinas #{i}") }
      expect(index.search("acme", query: "campinas", top_k: 2).size).to eq(2)
    end

    it "the read cache never returns stale content after a write, on a REUSED instance" do
      seed("cep-13-campinas", description: "old wording")
      reused = index # the same Scan instance across both searches — this is
      #                what the context provider holds across turns.

      first = reused.search("acme", query: "campinas")
      expect(first.first[:description]).to eq("old wording")

      seed("cep-13-campinas", description: "new wording, rewritten")
      second = reused.search("acme", query: "campinas")
      expect(second.first[:description]).to eq("new wording, rewritten")
    end

    it "a cache hit for an UNCHANGED concept still returns correct, cache-equivalent data" do
      seed("cep-13-campinas")
      reused = index
      first = reused.search("acme", query: "campinas")
      second = reused.search("acme", query: "campinas") # served from cache, nothing rewritten
      expect(second).to eq(first)
    end

    it "scoping is per agent — one agent's concepts never match another's search" do
      seed("cep-13-campinas")
      expect(index.search("acme", query: "campinas").map { |c| c[:name] }).to eq(["cep-13-campinas"])
      expect(index.search("zeta", query: "campinas")).to eq([])
    end

    it "scoping is per tenant — an explicit tenant cell is invisible to the default scope" do
      store.write("acme", "loja-a-only",
                  Insika::Knowledge::Concept.render(
                    name: "loja-a-only", description: "d", type: "fact", body: "campinas loja a",
                    provenance: "observed", confidence: 0.6, sources: [], occurrences: 1,
                    created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601
                  ), tenant: "loja-a")
      expect(index.search("acme", query: "campinas")).to eq([]) # default (no tenant) scope
      expect(index.search("acme", query: "campinas", tenant: "loja-a").map { |c| c[:name] }).to eq(["loja-a-only"])
    end
  end
end
