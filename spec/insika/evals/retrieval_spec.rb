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
    expect(results.dig("paraphrase-no-overlap", "candidate_recall", "on")).to eq("0/1")
    expect(results.dig("outside-note-window", "candidate_recall", "on")).to eq("0/1")
    expect(results.dig("lexical-ambiguity", "candidate_recall")).to eq("off" => "0/1", "on" => "1/1")
    expect(results.dig("provider-failure", "on", "selected")).to eq(["cedar-delivery"])
    expect(results.dig("provider-failure", "on", "events")).to include(:provider_warning)
    %w[expired-fact tenant-isolation deleted-concept].each do |id|
      expect(results.dig(id, "on", "context_correct")).to be(true)
    end
    expect(results.dig("tenant-isolation", "on", "isolation_safe")).to be(true)
  end

  it "derives recall from observed candidates even for the known missed cases" do
    %w[paraphrase-no-overlap outside-note-window].each do |id|
      shape = RetrievalEval::SHAPES.fetch(id)
      expect(described_class.recall(shape, { "candidates" => [] }, enabled: true)).to eq("0/1")
      expect(described_class.recall(shape,
        { "candidates" => ["#{shape.target.delete_prefix('note:')} answer"] }, enabled: true)).to eq("1/1")
    end
  end

  it "uses only emitted knowledge summaries and never transmits another tenant's marker" do
    knowledge_case = described_class.cases.find { |item| item.id == "lexical-ambiguity" }
    selected = described_class.measure(knowledge_case, RetrievalEval::SHAPES.fetch(knowledge_case.id), true)
    expect(selected.fetch("emitted_context")).to include("cedar arrives Tuesday")
    expect(selected.fetch("emitted_context")).not_to include("delivery detail")

    tenant_case = described_class.cases.find { |item| item.id == "tenant-isolation" }
    [false, true].each do |enabled|
      row = described_class.measure(tenant_case, RetrievalEval::SHAPES.fetch(tenant_case.id), enabled)
      expect(row.fetch("isolation_safe")).to be(true)
      expect(row.fetch("candidates").join).not_to include("PRIVATE_SCOPE_LEAK")
      expect(row.fetch("emitted_context")).not_to include("PRIVATE_SCOPE_LEAK")
    end
  end
end
