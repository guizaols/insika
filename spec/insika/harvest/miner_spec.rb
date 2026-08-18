# frozen_string_literal: true

require "spec_helper"
require "json"

# C2 — the one place harvest asks a model for anything. Pure over an injected
# ask (the Refinement::Proposer shape); everything it produces is data the
# command then filters (negative list, grounding, dedup) and a human then
# gates. The provider touch stays inside MinerFactory's lazy ask.
RSpec.describe Insika::Harvest do
  describe "DEFAULT_PROMPT" do
    it "tells the model to reference IDs only, never invent a product (D3)" do
      expect(described_class::DEFAULT_PROMPT).to match(/reference products by their ID only/i)
      expect(described_class::DEFAULT_PROMPT).to match(/never invent/i)
    end
  end

  def parse(prompt: "p", json: nil, counts: [10], max: 10, model: "m")
    miner = described_class::Miner.new(ask: ->(_p) { json }, model: model)
    miner.mine(prompt: prompt, message_counts: counts, max_proposals: max)
  end

  let(:good_json) do
    JSON.dump([
                { "name" => "pix-recovery-followup",
                  "description" => "Return to the customer when a PIX payment is pending",
                  "body" => "Ask the customer to check the payment confirmation.",
                  "triggers" => %w[pix pagamento],
                  "rationale" => "The pilot never returned for pending payments",
                  "evidence_turns" => [3, 5] }
              ])
  end

  describe "Miner" do
    it "a pack prompt replaces DEFAULT_PROMPT wholesale (the ask sees it)" do
      seen = nil
      miner = described_class::Miner.new(ask: ->(prompt) { seen = prompt; "[]" }, model: "m")
      miner.mine(prompt: "the pack's own words", message_counts: [10], max_proposals: 5)
      expect(seen).to eq("the pack's own words")
    end

    it "parses fenced JSON" do
      result = parse(json: "```json\n#{good_json}\n```")
      expect(result[:skills].size).to eq(1)
      expect(result[:skills].first["name"]).to eq("pix-recovery-followup")
    end

    it "prose instead of JSON raises Unusable, loudly (clean-looking silence is a lie)" do
      expect { parse(json: "here is what I propose: ...") }
        .to raise_error(Insika::Harvest::Miner::Unusable)
    end

    it "a non-array JSON answer raises Unusable" do
      expect { parse(json: '{"skills": []}') }
        .to raise_error(Insika::Harvest::Miner::Unusable)
    end

    it "drops schema-violating skills and counts the drop" do
      result = parse(json: JSON.dump([
                                       { "name" => "ok", "description" => "d", "body" => "b" },
                                       { "name" => "no-body" },
                                       "not a hash"
                                     ]))
      expect(result[:skills].map { |s| s["name"] }).to eq(["ok"])
      expect(result[:dropped]["schema"]).to eq(2)
    end

    it "drops a skill carrying a key OUTSIDE the schema — a model-authored `origin` is a provenance lie (D3)" do
      result = parse(json: JSON.dump([
                                       { "name" => "n", "description" => "d", "body" => "b",
                                         "origin" => ["sess_8f3c"] }
                                     ]))
      expect(result[:skills]).to eq([])
      expect(result[:dropped]["unknown_key"]).to eq(1)
    end

    it "drops oversized name/description/body/triggers/rationale, counted" do
      result = parse(json: JSON.dump([
                                       { "name" => "x" * 65, "description" => "d", "body" => "b" },
                                       { "name" => "n", "description" => "d" * 301, "body" => "b" },
                                       { "name" => "n2", "description" => "d", "body" => "b" * 6001 },
                                       { "name" => "n3", "description" => "d", "body" => "b",
                                         "triggers" => (1..11).map(&:to_s) },
                                       { "name" => "n4", "description" => "d", "body" => "b",
                                         "triggers" => ["ok", "x" * 81] },
                                       { "name" => "n5", "description" => "d", "body" => "b",
                                         "rationale" => "r" * 501 },
                                       { "name" => "ok", "description" => "d", "body" => "b" }
                                     ]))
      expect(result[:skills].map { |s| s["name"] }).to eq(["ok"])
      expect(result[:dropped]["oversized"]).to eq(6)
    end

    it "drops bad evidence_turns (non-integer, negative, or out of every session's range)" do
      result = parse(json: JSON.dump([
                                       { "name" => "a", "description" => "d", "body" => "b",
                                         "evidence_turns" => [3, "5"] },
                                       { "name" => "b", "description" => "d", "body" => "b",
                                         "evidence_turns" => [-1] },
                                       { "name" => "c", "description" => "d", "body" => "b",
                                         "evidence_turns" => [20] },
                                       { "name" => "ok", "description" => "d", "body" => "b",
                                         "evidence_turns" => [3] }
                                     ]))
      expect(result[:skills].map { |s| s["name"] }).to eq(["ok"])
      expect(result[:dropped]["bad_turns"]).to eq(3)
    end

    it "an index out of EVERY session's range is dropped; one that fits any session survives" do
      result = parse(counts: [3, 8], json: JSON.dump([
                                                      { "name" => "big", "description" => "d", "body" => "b",
                                                        "evidence_turns" => [300] },
                                                      { "name" => "small", "description" => "d", "body" => "b",
                                                        "evidence_turns" => [5] }
                                                    ]))
      expect(result[:skills].map { |s| s["name"] }).to eq(["small"])
      expect(result[:dropped]["bad_turns"]).to eq(1)
    end

    it "drops exact duplicates within one answer, all but the first, counted" do
      item = { "name" => "dup", "description" => "same", "body" => "same" }
      result = parse(json: JSON.dump([item, item]))
      expect(result[:skills].size).to eq(1)
      expect(result[:dropped]["duplicate"]).to eq(1)
    end

    it "caps survivors at max_proposals (the cap counts as a drop)" do
      result = parse(max: 3, json: JSON.dump(
                                      (1..5).map { |i| { "name" => "s#{i}", "description" => "d", "body" => "b" } }
                                    ))
      expect(result[:skills].size).to eq(3)
      expect(result[:dropped]["capped"]).to eq(2)
    end

    it "cost is nil for a plain String ask and present for a message-bearing one" do
      expect(parse(json: "[]")[:cost]).to be_nil

      message = Class.new do
        attr_reader :input_tokens, :output_tokens, :cached_tokens

        def initialize
          @input_tokens = 100
          @output_tokens = 40
          @cached_tokens = 60
        end

        def content = "[]"
      end.new
      miner = described_class::Miner.new(ask: ->(_prompt) { message }, model: "m")
      expect(miner.mine(prompt: "p", message_counts: [10])[:cost])
        .to eq("spent" => 200, "cached" => 60)
    end

    it "records the model ref on the miner" do
      miner = described_class::Miner.new(ask: ->(_p) { "[]" }, model: "utility_model")
      expect(miner.model).to eq("utility_model")
    end
  end

  describe "MinerFactory" do
    let(:ask_factory) { ->(_model, _provider) { ->(_prompt) { "[]" } } }

    it "resolves the config's miner.model ref first (D12)" do
      miner = described_class::MinerFactory.build(
        { "miner" => { "model" => "deepseek-v4-flash" } },
        utility_model: "utility-model", ask_factory: ask_factory
      )
      expect(miner.model).to eq("deepseek-v4-flash")
    end

    it "falls back to the platform utility_model" do
      miner = described_class::MinerFactory.build({ "enabled" => true },
                                                  utility_model: "utility-model",
                                                  ask_factory: ask_factory)
      expect(miner.model).to eq("utility-model")
    end

    it "returns nil when no model is resolvable — the feature is inert, never guessed" do
      expect(described_class::MinerFactory.build(
               { "enabled" => true }, utility_model: nil, ask_factory: ask_factory
             )).to be_nil
    end

    it "never touches the provider when an ask_factory is injected" do
      described_class::MinerFactory.build(
        { "enabled" => true, "miner" => { "model" => "m" } },
        utility_model: nil, ask_factory: ask_factory, llm: Object.new
      )
      expect(true).to be(true)
    end

    it "builds the real ask lazily via ruby_llm when no ask_factory is given" do
      miner = described_class::MinerFactory.build(
        { "enabled" => true, "miner" => { "model" => "m" } }
      )
      expect(miner).to be_a(Insika::Harvest::Miner)
    end
  end
end