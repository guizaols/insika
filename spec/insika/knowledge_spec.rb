# frozen_string_literal: true

require "json"

RSpec.describe Insika::Knowledge do
  describe "DEFAULT_PROMPT" do
    it "states the durable-concept rules, the answer shape and the never-invent rules" do
      prompt = described_class::DEFAULT_PROMPT
      expect(prompt).to include("JSON")
      expect(prompt).to include("name")
      expect(prompt).to include("body")
      expect(prompt).to include("invent")
    end
  end

  describe Insika::Knowledge::Concept do
    it "parses a concept's frontmatter and body" do
      raw = <<~MD
        ---
        name: cep-sudeste-cd-campinas
        description: "CEPs 13xxx ship from Campinas"
        type: fact
        provenance: observed
        confidence: 0.6
        sources: ["sess_1"]
        occurrences: 1
        created_at: "2026-08-24T00:00:00Z"
        updated_at: "2026-08-24T00:00:00Z"
        ---

        Orders to CEP range 13000-13999 ship from Campinas.
      MD

      parsed = described_class.parse(raw)
      expect(parsed[:name]).to eq("cep-sudeste-cd-campinas")
      expect(parsed[:type]).to eq("fact")
      expect(parsed[:provenance]).to eq("observed")
      expect(parsed[:sources]).to eq(["sess_1"])
      expect(parsed[:body]).to eq("Orders to CEP range 13000-13999 ship from Campinas.")
    end

    it "returns nil without a frontmatter block or without a name" do
      expect(described_class.parse("just prose, no frontmatter")).to be_nil
      expect(described_class.parse("---\ndescription: d\n---\nbody")).to be_nil
    end

    it "renders and round-trips through parse" do
      rendered = described_class.render(
        name: "frete-gratis-acima-199", description: "d", type: "policy", body: "the body",
        provenance: "observed", confidence: 0.6, sources: %w[sess_1], occurrences: 1,
        created_at: "2026-08-24T00:00:00Z", updated_at: "2026-08-24T00:00:00Z"
      )
      parsed = described_class.parse(rendered)
      expect(parsed[:name]).to eq("frete-gratis-acima-199")
      expect(parsed[:body]).to eq("the body")
      expect(parsed[:confidence]).to eq(0.6)
    end
  end

  describe ".stamp_and_render" do
    it "stamps provenance/confidence/sources/occurrences the model never supplies, and redacts the body" do
      rendered = described_class.stamp_and_render(
        { "name" => "leaks-a-cpf", "description" => "d", "type" => "fact",
          "body" => "the customer's CPF is 123.456.789-00" },
        session_id: "sess_42"
      )
      parsed = described_class::Concept.parse(rendered)
      expect(parsed[:provenance]).to eq("observed")
      expect(parsed[:confidence]).to eq(0.6)
      expect(parsed[:sources]).to eq(["sess_42"])
      expect(parsed[:occurrences]).to eq(1)
      expect(parsed[:body]).not_to include("123.456.789-00")
      expect(parsed[:body]).to include("REDACTED")
    end
  end

  describe Insika::Knowledge::Extractor do
    def clean_drops
      { "schema" => 0, "unknown_key" => 0, "bad_type" => 0, "oversized" => 0, "duplicate" => 0, "capped" => 0 }
    end

    def concept(overrides = {})
      { "name" => "cep-13", "description" => "d", "type" => "fact", "body" => "b" }.merge(overrides)
    end

    it "parses fenced JSON from a plain String ask and reports no cost" do
      extractor = described_class.new(ask: ->(_prompt) { "```json\n#{JSON.generate([concept])}\n```" })
      result = extractor.extract(prompt: "p")
      expect(result[:concepts]).to eq([concept])
      expect(result[:dropped]).to eq(clean_drops)
      expect(result[:cost]).to be_nil
    end

    it "reports the cost when the ask answers with a message carrying token counts" do
      message = Struct.new(:content, :input_tokens, :output_tokens, :cached_tokens)
                .new(JSON.generate([concept]), 100, 20, 500)
      extractor = described_class.new(ask: ->(_prompt) { message }, model: "utility_model")
      result = extractor.extract(prompt: "p")
      expect(result[:cost]).to eq("spent" => 620, "cached" => 500)
    end

    it "a prose answer raises Unusable" do
      extractor = described_class.new(ask: ->(_prompt) { "I noticed a few things worth remembering." })
      expect { extractor.extract(prompt: "p") }.to raise_error(described_class::Unusable)
    end

    it "a non-array JSON answer raises Unusable" do
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate({ "name" => "x" }) })
      expect { extractor.extract(prompt: "p") }.to raise_error(described_class::Unusable, /array/)
    end

    it "drops concepts missing a required key, counted under schema" do
      extractor = described_class.new(
        ask: ->(_prompt) { JSON.generate([concept.reject { |k, _| k == "body" }, concept]) }
      )
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:dropped]["schema"]).to eq(1)
    end

    it "drops a model-authored provenance/confidence/sources — the escape this extractor blocks" do
      extractor = described_class.new(
        ask: ->(_prompt) { JSON.generate([concept("provenance" => "policy", "confidence" => 1.0), concept]) }
      )
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:concepts].first).not_to have_key("provenance")
      expect(result[:dropped]["unknown_key"]).to eq(1)
    end

    it "drops a type outside the configured allowlist, counted under bad_type" do
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate([concept("type" => "opinion"), concept]) },
                                      types: %w[fact policy])
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:dropped]["bad_type"]).to eq(1)
    end

    it "drops a badly-shaped name (not a lowercase hyphen slug), counted under schema" do
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate([concept("name" => "Not A Slug!"), concept]) })
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:dropped]["schema"]).to eq(1)
    end

    it "drops an oversized name, description or body, counted under oversized" do
      extractor = described_class.new(
        ask: ->(_prompt) { JSON.generate([concept("body" => "x" * 2001), concept]) }
      )
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:dropped]["oversized"]).to eq(1)
    end

    it "drops exact duplicates within one answer, keeping the first" do
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate([concept, concept, concept("name" => "other")]) })
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(2)
      expect(result[:dropped]["duplicate"]).to eq(1)
    end

    it "caps the survivors at max_concepts, counting the overflow under capped" do
      many = (1..15).map { |i| concept("name" => "c-#{i}") }
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate(many) })
      result = extractor.extract(prompt: "p", max_concepts: 5)
      expect(result[:concepts].size).to eq(5)
      expect(result[:dropped]["capped"]).to eq(10)
    end

    it "a non-Hash element is a schema drop, never an unknown_key" do
      extractor = described_class.new(ask: ->(_prompt) { JSON.generate(["cep-13", concept]) })
      result = extractor.extract(prompt: "p")
      expect(result[:concepts].size).to eq(1)
      expect(result[:dropped]["schema"]).to eq(1)
      expect(result[:dropped]["unknown_key"]).to eq(0)
    end
  end

  describe Insika::Knowledge::ExtractorFactory do
    let(:ask_factory) { ->(_model, _provider) { ->(_prompt) { "[]" } } }

    it "resolves the config's model ref first" do
      extractor = described_class.build({ "extract" => true, "model" => "deepseek-v4-flash" },
                                        utility_model: "utility-model", ask_factory: ask_factory)
      expect(extractor.model).to eq("deepseek-v4-flash")
    end

    it "falls back to the platform utility_model" do
      extractor = described_class.build({ "extract" => true }, utility_model: "utility-model", ask_factory: ask_factory)
      expect(extractor.model).to eq("utility-model")
    end

    it "returns nil when no model is resolvable — the feature is inert, never guessed" do
      expect(described_class.build({ "extract" => true }, utility_model: nil, ask_factory: ask_factory)).to be_nil
    end

    it "defaults the allowed types to DEFAULT_TYPES, or takes the profile's own list" do
      default = described_class.build({ "extract" => true, "model" => "m" }, ask_factory: ask_factory)
      expect(default.types).to eq(Insika::Knowledge::DEFAULT_TYPES)

      scoped = described_class.build({ "extract" => true, "model" => "m", "types" => %w[fact] },
                                     ask_factory: ask_factory)
      expect(scoped.types).to eq(%w[fact])
    end

    it "builds the real ask lazily via ruby_llm when no ask_factory is given" do
      extractor = described_class.build({ "extract" => true, "model" => "m" })
      expect(extractor).to be_a(Insika::Knowledge::Extractor)
    end
  end
end
