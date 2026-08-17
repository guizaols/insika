# frozen_string_literal: true

require "json"

RSpec.describe Insika::Distill do
  describe "DEFAULT_PROMPT" do
    it "states the durable-fact rules, the answer shape and the never-guess rules" do
      prompt = described_class::DEFAULT_PROMPT
      expect(prompt).to include("durable")
      expect(prompt).to include("JSON")
      expect(prompt).to include("name")
      expect(prompt).to include("value")
      expect(prompt).to include("invent")
    end
  end

  describe Insika::Distill::Distiller do
    def clean_drops
      { "schema" => 0, "unknown_key" => 0, "oversized" => 0, "bad_turns" => 0, "duplicate" => 0,
        "capped" => 0 }
    end

    it "parses fenced JSON from a plain String ask and reports no cost" do
      distiller = described_class.new(
        ask: ->(_prompt) { "```json\n#{JSON.generate([{ "name" => "size", "value" => "M" }])}\n```" }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals]).to eq([{ "name" => "size", "value" => "M" }])
      expect(result[:dropped]).to eq(clean_drops)
      expect(result[:cost]).to be_nil
    end

    it "reports the cost when the ask answers with a message carrying token counts" do
      message = Struct.new(:content, :input_tokens, :output_tokens, :cached_tokens)
                .new(JSON.generate([{ "name" => "size", "value" => "M" }]), 100, 20, 500)
      distiller = described_class.new(ask: ->(_prompt) { message }, model: "utility_model")
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:cost]).to eq("spent" => 620, "cached" => 500)
      expect(result[:proposals].size).to eq(1)
    end

    it "a prose answer raises Unusable (loud — empty output must not read as clean traffic)" do
      distiller = described_class.new(ask: ->(_prompt) { "I noticed this customer prefers medium sizes." })
      expect { distiller.distill(prompt: "p", message_count: 10) }
        .to raise_error(described_class::Unusable)
    end

    it "a non-array JSON answer raises Unusable" do
      distiller = described_class.new(ask: ->(_prompt) { JSON.generate({ "name" => "x" }) })
      expect { distiller.distill(prompt: "p", message_count: 10) }
        .to raise_error(described_class::Unusable, /array/)
    end

    it "drops proposals missing name or value, counted under schema" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([{ "name" => "size" }, { "value" => "M" }, { "name" => "ok", "value" => "1" }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(1)
      expect(result[:dropped]["schema"]).to eq(2)
    end

    it "drops a non-string value and an out-of-range confidence, counted under schema" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([{ "name" => "size", "value" => 5 },
                                          { "name" => "size", "value" => "M", "confidence" => 1.5 },
                                          { "name" => "size", "value" => "M", "confidence" => "high" },
                                          { "name" => "size", "value" => "M", "confidence" => 0.9 }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(1)
      expect(result[:proposals].first["confidence"]).to eq(0.9)
      expect(result[:dropped]["schema"]).to eq(3)
    end

    it "drops a model-authored scope — the cross-tenant escape (D1) — counted under unknown_key" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([{ "name" => "size", "value" => "M", "scope" => "acme:other-customer" },
                                          { "name" => "size", "value" => "M" }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(1)
      expect(result[:proposals].first).not_to have_key("scope")
      expect(result[:dropped]["unknown_key"]).to eq(1)
    end

    it "drops an oversized name or value, counted under oversized" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([{ "name" => "x" * 121, "value" => "M" },
                                          { "name" => "size", "value" => "v" * 501 },
                                          { "name" => "size", "value" => "M" }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(1)
      expect(result[:dropped]["oversized"]).to eq(2)
    end

    it "drops proposals whose turns are bad: non-integer, negative, out of range, too many" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([
          { "name" => "a", "value" => "1", "turns" => ["x"] },
          { "name" => "b", "value" => "2", "turns" => [-1] },
          { "name" => "c", "value" => "3", "turns" => [99] },          # >= message_count
          { "name" => "d", "value" => "4", "turns" => (1..21).to_a },  # > MAX_TURNS
          { "name" => "e", "value" => "5", "turns" => [2, 4] },
          { "name" => "f", "value" => "6" }                            # no turns key at all
        ]) }
      )
      result = distiller.distill(prompt: "p", message_count: 20)
      expect(result[:proposals].map { |p| p["name"] }).to eq(%w[e f])
      expect(result[:dropped]["bad_turns"]).to eq(4)
    end

    it "drops exact duplicates within one answer, keeping the first" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate([{ "name" => "size", "value" => "M" },
                                          { "name" => "size", "value" => "M" },
                                          { "name" => "size", "value" => "L" }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(2)
      expect(result[:dropped]["duplicate"]).to eq(1)
    end

    it "caps the survivors at max_proposals, counting the overflow under capped" do
      many = (1..15).map { |i| { "name" => "f#{i}", "value" => "v" } }
      distiller = described_class.new(ask: ->(_prompt) { JSON.generate(many) })
      result = distiller.distill(prompt: "p", message_count: 10, max_proposals: 5)
      expect(result[:proposals].size).to eq(5)
      expect(result[:dropped]["capped"]).to eq(10)
    end

    it "a non-Hash element is a schema drop, never an unknown_key" do
      distiller = described_class.new(
        ask: ->(_prompt) { JSON.generate(["size", { "name" => "size", "value" => "M" }]) }
      )
      result = distiller.distill(prompt: "p", message_count: 10)
      expect(result[:proposals].size).to eq(1)
      expect(result[:dropped]["schema"]).to eq(1)
      expect(result[:dropped]["unknown_key"]).to eq(0)
    end

    it "records the model ref on the instance" do
      distiller = described_class.new(ask: ->(_prompt) { "[]" }, model: "utility_model")
      expect(distiller.model).to eq("utility_model")
    end
  end

  describe Insika::Distill::DistillerFactory do
    let(:ask_factory) { ->(_model, _provider) { ->(_prompt) { "[]" } } }

    it "resolves the config's model ref first" do
      distiller = described_class.build(
        { "enabled" => true, "model" => "deepseek-v4-flash" },
        utility_model: "utility-model", ask_factory: ask_factory
      )
      expect(distiller.model).to eq("deepseek-v4-flash")
    end

    it "falls back to the platform utility_model" do
      distiller = described_class.build(
        { "enabled" => true }, utility_model: "utility-model", ask_factory: ask_factory
      )
      expect(distiller.model).to eq("utility-model")
    end

    it "returns nil when no model is resolvable — the feature is inert, never guessed (D4)" do
      expect(described_class.build({ "enabled" => true }, utility_model: nil, ask_factory: ask_factory)).to be_nil
    end

    it "never touches the provider when an ask_factory is injected" do
      described_class.build({ "enabled" => true, "model" => "m" },
                            utility_model: nil, ask_factory: ask_factory, llm: Object.new)
      expect(true).to be(true)
    end

    it "builds the real ask lazily via ruby_llm when no ask_factory is given" do
      distiller = described_class.build({ "enabled" => true, "model" => "m" })
      expect(distiller).to be_a(Insika::Distill::Distiller)
    end
  end
end
