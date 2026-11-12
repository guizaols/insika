# frozen_string_literal: true

require "spec_helper"
require "ruby_llm"

RSpec.describe "Insika::Wiring::Graph.metered_llm" do
  let(:backend) { Insika::Stores::Memory.new }
  let(:store) { Insika::ModelMetricsStore.new(store: backend) }
  let(:spine) { Struct.new(:model_metrics_store).new(store) }
  let(:tokens) { Struct.new(:input, :output, :cache_read, :cache_write, :thinking).new(1000, 200, 0, 0, 0) }

  it "records a distill or harvest request with its agent, tokens and cost, outside any task" do
    llm = Insika::Wiring::Graph.metered_llm(nil, spine, "harvest", { "agent" => "shop" })
    meter = llm.config.instrumenter
    allow(Insika::Telemetry::PeakPricing).to receive(:apply) { |cost, **| cost * 2 }
    meter.instrument("request.ruby_llm", provider: "deepseek", model: "deepseek-flash") do
      meter.instrument("usage.ruby_llm", provider: "deepseek", model: "deepseek-flash", status: :succeeded,
        tokens: tokens, cost: Struct.new(:total).new(0.25))
    end

    row = backend.entries(Insika::ModelMetricsStore::SCOPE, "").first.last
    expect(row).to include("task_id" => nil, "operation" => "harvest", "agent" => "shop", "provider" => "deepseek",
      "model" => "deepseek-flash", "status" => "succeeded", "input_tokens" => 1000, "output_tokens" => 200, "cost" => 0.5)
    expect(RubyLLM.config.instrumenter).not_to equal(meter)
  end

  it "prices a real distiller call through RubyLLM, peak hours included" do
    RubyLLM.configure { |c| c.deepseek_api_key ||= "test" }
    body = { "id" => "x", "model" => "deepseek-flash",
             "choices" => [{ "index" => 0, "finish_reason" => "stop",
                             "message" => { "role" => "assistant", "content" => '{"items":[]}' } }],
             "usage" => { "prompt_tokens" => 1_000_000, "completion_tokens" => 0, "total_tokens" => 1_000_000 } }
    stub_llm_http do |stub|
      stub.post(%r{chat/completions\z}) { [200, { "Content-Type" => "application/json" }, JSON.generate(body)] }
    end
    allow(Insika::Telemetry::PeakPricing).to receive(:apply) { |cost, **| cost * 2 }
    config = { "model" => "deepseek/deepseek-flash", "agent" => "shop" }
    distiller = Insika::Distill::DistillerFactory.build(config,
      llm: Insika::Wiring::Graph.metered_llm(nil, spine, "distill", config))

    expect(distiller.distill(prompt: "p", message_count: 2)[:proposals]).to eq([])
    row = backend.entries(Insika::ModelMetricsStore::SCOPE, "").first.last
    expect(row).to include("operation" => "distill", "agent" => "shop", "provider" => "deepseek",
      "model" => "deepseek-flash", "status" => "succeeded", "attempts" => 1, "input_tokens" => 1_000_000)
    expect(row["cost"]).to be_within(1e-9).of(0.30) # 0.15 per million input, doubled at peak
    expect(row["completed_at"]).not_to be_nil
  end

  it "leaves an llm without a config untouched" do
    fake = Object.new
    expect(Insika::Wiring::Graph.metered_llm(fake, spine, "distill", {})).to equal(fake)
  end
end
