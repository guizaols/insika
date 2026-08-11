# frozen_string_literal: true

require "spec_helper"

# — estimated cost. Pricing is PURE: an operator-declared rates table
# (USD per million tokens) times the turn's usage. Proves the token accounting
# (cached is a subset of input, cache-creation is not), the "unknown model -> nil"
# rule (a missing price is not a zero cost) and that a malformed table can never
# raise.
RSpec.describe Insika::Telemetry::Pricing do
  # deepseek-chat-ish numbers; the values only matter as arithmetic.
  let(:rates) do
    { "deepseek/deepseek-chat" => { "input" => 0.27, "output" => 1.10,
                                    "cached_input" => 0.07, "cache_write" => 0.34 } }
  end

  subject(:pricing) { described_class.new(rates) }

  it "prices input + output at the declared per-million rates" do
    cost = described_class.new({ "m" => { "input" => 1.0, "output" => 2.0 } })
             .cost({ model: "m", input_tokens: 1_000_000, output_tokens: 500_000 })
    expect(cost).to eq(2.0) # 1.0 + (0.5 * 2.0)
  end

  it "bills cached tokens at cached_input and subtracts them from the fresh input" do
    cost = described_class.new({ "m" => { "input" => 1.0, "output" => 0.0, "cached_input" => 0.1 } })
             .cost({ model: "m", input_tokens: 1_000_000, cached_tokens: 400_000, output_tokens: 0 })
    expect(cost).to eq(0.64) # 0.6M fresh @1.0 + 0.4M cached @0.1
  end

  it "leaves cached tokens at the input rate when no cached_input is declared" do
    cost = described_class.new({ "m" => { "input" => 1.0, "output" => 0.0 } })
             .cost({ model: "m", input_tokens: 1_000_000, cached_tokens: 400_000, output_tokens: 0 })
    expect(cost).to eq(1.0) # cached is a SUBSET of input — not subtracted, not double-counted
  end

  it "bills cache-creation tokens on top (they are not inside input_tokens)" do
    cost = described_class.new({ "m" => { "input" => 1.0, "output" => 0.0, "cache_write" => 1.25 } })
             .cost({ model: "m", input_tokens: 1_000_000, cache_creation_tokens: 1_000_000, output_tokens: 0 })
    expect(cost).to eq(2.25)
  end

  it "falls back to the input rate for cache-creation when cache_write is absent" do
    cost = described_class.new({ "m" => { "input" => 2.0, "output" => 0.0 } })
             .cost({ model: "m", input_tokens: 0, cache_creation_tokens: 1_000_000, output_tokens: 0 })
    expect(cost).to eq(2.0)
  end

  describe "model lookup" do
    it "matches the full provider/model id" do
      expect(pricing.cost({ model: "deepseek/deepseek-chat", input_tokens: 1_000_000, output_tokens: 0 }))
        .to eq(0.27)
    end

    it "matches the bare model id the provider actually reports" do
      expect(pricing.cost({ model: "deepseek-chat", input_tokens: 1_000_000, output_tokens: 0 })).to eq(0.27)
    end

    it "unknown model -> nil (a missing price is NOT a zero cost)" do
      expect(pricing.cost({ model: "gpt-9", input_tokens: 1_000_000, output_tokens: 1 })).to be_nil
    end

    it "usage without a model -> nil" do
      expect(pricing.cost({ input_tokens: 10, output_tokens: 2 })).to be_nil
      expect(pricing.cost(nil)).to be_nil
    end
  end

  describe ".parse (the operator's env)" do
    it "reads a JSON object into a usable table" do
      table = described_class.parse('{"m":{"input":1.0,"output":2.0}}')
      expect(table).not_to be_empty
      expect(table.cost({ model: "m", input_tokens: 1_000_000, output_tokens: 0 })).to eq(1.0)
    end

    it "unset/blank -> empty (no cost reported, no error)" do
      expect(described_class.parse(nil)).to be_empty
      expect(described_class.parse("  ")).to be_empty
    end

    it "malformed JSON or a non-object -> empty, never raises (config must not stop a boot)" do
      expect(described_class.parse("{not json")).to be_empty
      expect(described_class.parse("[1,2]")).to be_empty
    end

    it "drops entries that are not a rate hash" do
      expect(described_class.parse('{"m":"free","n":{"nope":1}}')).to be_empty
    end
  end
end
