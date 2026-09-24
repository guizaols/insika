# frozen_string_literal: true

require "spec_helper"
require_relative "../../../evals/retrieval/run"

RSpec.describe RetrievalEval do
  it "compares the same golden cases through the real providers and index" do
    results = described_class.run(repeats: 2)
    expect(results.keys).to contain_exactly(*RetrievalEval::SHAPES.keys)
    expect(results.dig("lexical-ambiguity", "off", "context_correct")).to be(false)
    expect(results.dig("lexical-ambiguity", "on", "context_correct")).to be(true)
    expect(results.dig("lexical-ambiguity", "on", "answer_correct")).to be(true)
    expect(results.dig("older-memory", "off", "context_correct")).to be(false)
    expect(results.dig("older-memory", "on", "context_correct")).to be(true)
    expect(results.dig("paraphrase-no-overlap", "candidate_recall", "on")).to eq("0/1 (no lexical candidate)")
    expect(results.dig("outside-note-window", "candidate_recall", "on")).to eq("0/1 (outside candidate window)")
    expect(results.dig("lexical-ambiguity", "candidate_recall")).to eq("off" => "0/1", "on" => "1/1")
    expect(results.dig("provider-failure", "on", "selected")).to eq(["cedar-delivery"])
    expect(results.dig("provider-failure", "on", "events")).to include(:provider_warning)
    %w[expired-fact tenant-isolation deleted-concept].each do |id|
      expect(results.dig(id, "on", "context_correct")).to be(true)
    end
  end
end
