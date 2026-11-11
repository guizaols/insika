# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/reprice_history"

RSpec.describe "Insika::RepriceHistory" do
  let(:off_peak) { "2026-11-10T12:00:00Z" } # a Tuesday
  let(:peak) { "2026-11-10T02:00:00Z" }     # Tuesday 10:00 in Beijing

  def row(provider, model, at, attempts: 1, cost: 1.0, **tokens)
    { "provider" => provider, "model" => model, "completed_at" => at, "attempts" => attempts, "cost" => cost,
      "input_tokens" => 2_000, "cache_read_tokens" => 8_000, "output_tokens" => 500 }
      .merge(tokens.transform_keys { |bucket| "#{bucket}_tokens" })
  end

  def cost(...) = Insika::RepriceHistory.cost(row(...))

  it "prices DeepSeek from its tokens, at double in peak hours" do
    expect(cost("deepseek", "deepseek-flash", off_peak)).to be_within(1e-12).of(0.000624)
    expect(cost("deepseek", "deepseek-v4-flash", peak)).to be_within(1e-12).of(0.001248)
    expect(cost("deepseek", "deepseek-v4-pro", off_peak)).to be_within(1e-12).of(0.002486)
    expect(cost("deepseek", "deepseek-flash", "2026-10-01T02:00:00Z")).to be_within(1e-12).of(0.000624) # holiday
  end

  it "prices OpenAI cache writes, and the long-context rates past 272K prompt tokens" do
    short = cost("openai", "gpt-6-luna", peak, cache_write: 1_000)
    expect(short).to be_within(1e-12).of((2_000 * 0.1 + 8_000 * 0.01 + 1_000 * 0.125 + 500 * 0.5) / 1e6)
    long = cost("openai", "openai/gpt-6-luna", peak, cache_read: 300_000)
    expect(long).to be_within(1e-12).of((2_000 * 0.2 + 300_000 * 0.02 + 500 * 0.75) / 1e6)
  end

  it "leaves what no price list covers" do
    expect(cost("deepseek", "deepseek-chat", off_peak)).to be_nil
    expect(cost("openrouter", "deepseek/deepseek-v4.1-flash", off_peak)).to be_nil
    expect(cost("deepseek", "deepseek-flash", "2026-09-01T12:00:00Z")).to be_nil # before this price list
    expect(cost("deepseek", "deepseek-flash", off_peak, cache_write: 10)).to be_nil # a bucket with no rate
    expect(cost("openai", "gpt-6-luna", off_peak, attempts: 2)).to be_nil # which attempt was long?
    expect(cost("deepseek", "deepseek-flash", off_peak, input: nil)).to be_nil
  end

  it "reprices a store and says what it did with each provider and model" do
    backend = Insika::Stores::Memory.new
    Insika::TaskStore.new(store: backend).create(id: "t", command: {})
    store = Insika::ModelMetricsStore.new(store: backend)
    { "a" => ["deepseek", "deepseek-flash", peak, 0.000624], "b" => ["deepseek", "deepseek-flash", off_peak, 0.000624],
      "c" => ["openrouter", "z-ai/glm-5.3-flash", peak, 0.5], "d" => ["mistral", "mistral-small-latest", peak, 0.1] }
      .each do |id, (provider, model, at, recorded)|
        base = { "request_id" => id, "at" => at, "provider" => provider, "model" => model }
        store.record(task_id: "t", entry: base.merge("type" => "llm_usage", "cost" => recorded, "input_tokens" => 2_000,
                                                     "cache_read_tokens" => 8_000, "output_tokens" => 500))
        store.record(task_id: "t", entry: base.merge("type" => "llm_request", "status" => "succeeded", "duration_ms" => 1))
      end
    to = Time.utc(2026, 11, 10, 20)

    result, found = Insika::RepriceHistory.call(store: store, to: to, apply: true)

    expect(result).to include("rows" => 4, "changed" => 1)
    expect(found.keys).to contain_exactly(
      ["deepseek", "deepseek-flash", "priced from the provider's price list"],
      ["openrouter", "z-ai/glm-5.3-flash", "left: the provider reported the billed amount"],
      ["mistral", "mistral-small-latest", "left: no price list here covers it"]
    )
    expect(found[["deepseek", "deepseek-flash", "priced from the provider's price list"]])
      .to include(rows: 2, peak: 1)
    expect(store.report(from: to - 86_400, to: to)["totals"]["cost"]).to be_within(1e-9).of(0.001872 + 0.6)
    expect(Insika::RepriceHistory.call(store: store, to: to, apply: true).first).to include("changed" => 0)
  end
end
