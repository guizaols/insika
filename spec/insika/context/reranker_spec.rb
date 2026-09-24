# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Reranker do
  let(:config) { { "provider" => "cohere", "model" => "rerank-v3.5", "timeout_seconds" => 2 } }
  let(:documents) { ["first", "second", "third"] }

  it "returns validated native result indexes in provider order" do
    result = Struct.new(:results).new([Struct.new(:index).new(2), Struct.new(:index).new(0)])
    llm = double(rerank: result)
    indexes = Async { described_class.new(llm: llm).select(query: "q", documents: documents,
                                                         config: config, top_k: 2) }.wait
    expect(indexes).to eq([2, 0])
    expect(llm).to have_received(:rerank).with("q", documents, provider: "cohere", model: "rerank-v3.5", top_n: 2)
  end

  it "skips empty input and rejects duplicate, missing, and out of range indexes" do
    llm = double
    reranker = described_class.new(llm: llm)
    expect(reranker.select(query: "q", documents: [], config: config, top_k: 2)).to be_nil
    [[0, 0], [3], [], ["0"]].each do |bad|
      allow(llm).to receive(:rerank).and_return(Struct.new(:results).new(bad.map { |i| Struct.new(:index).new(i) }))
      expect(Async { reranker.select(query: "q", documents: documents, config: config, top_k: 2) }.wait).to be_nil
    end
  end

  it "rejects an undersized response instead of dropping a lexical hit" do
    llm = double(rerank: Struct.new(:results).new([Struct.new(:index).new(0)]))
    result = Async { described_class.new(llm: llm).select(query: "q", documents: documents,
      config: config, top_k: 2) }.wait
    expect(result).to be_nil
  end

  it "accepts every candidate when fewer candidates exist than top_k" do
    llm = double(rerank: Struct.new(:results).new([Struct.new(:index).new(1), Struct.new(:index).new(0)]))
    result = Async { described_class.new(llm: llm).select(query: "q", documents: documents.first(2),
      config: config, top_k: 5) }.wait
    expect(result).to eq([1, 0])
  end

  it "falls back on provider errors without recording provider text" do
    llm = double
    allow(llm).to receive(:rerank).and_raise(StandardError, "secret body")
    events = []
    result = Async { described_class.new(llm: llm).select(query: "q", documents: documents,
      config: config, top_k: 2, emit: ->(type, data) { events << [type, data] }) }.wait
    expect(result).to be_nil
    expect(events.inspect).not_to include("secret body")
    expect(events.map(&:first)).to include(:provider_warning)
  end

  it "bounds the text sent to the provider with the token estimator" do
    llm = double
    allow(llm).to receive(:rerank) do |query, docs, **_opts|
      expect(Insika::TokenEstimator.estimate(query) + docs.sum { |doc| Insika::TokenEstimator.estimate(doc) })
        .to be <= 100
      Struct.new(:results).new([Struct.new(:index).new(0)])
    end
    result = Async { described_class.new(llm: llm).select(query: "q" * 10_000,
      documents: ["a" * 10_000, "b" * 10_000], config: config, top_k: 1, budget: 100) }.wait
    expect(result).to eq([0])
  end

  it "redacts secret-like query and document text before the provider call" do
    secret = "sk-abcdefghijklmnop1234"
    llm = double
    expect(llm).to receive(:rerank) do |query, docs, **_opts|
      expect(query).to include("peanuts", "[REDACTED:secret]")
      expect(docs.first).to include("allergy", "[REDACTED:secret]")
      expect([query, *docs].join).not_to include(secret)
      Struct.new(:results).new([Struct.new(:index).new(0)])
    end
    Async { described_class.new(llm: llm).select(query: "peanuts #{secret}",
      documents: ["allergy #{secret}"], config: config, top_k: 1) }.wait
  end

  it "times out and leaves lexical ordering available" do
    llm = double
    allow(llm).to receive(:rerank) { Async::Task.current.sleep(0.1) }
    result = Async { described_class.new(llm: llm).select(query: "q", documents: documents,
      config: config.merge("timeout_seconds" => 0.001), top_k: 2) }.wait
    expect(result).to be_nil
  end
end
