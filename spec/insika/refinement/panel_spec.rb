# frozen_string_literal: true

require "spec_helper"

# N models propose, the gate arbitrates. The cases that
# matter are the ones where the panel has to DECIDE something: which candidate won,
# what happens when one model is useless, and what stops the run from spending
# without a ceiling.
RSpec.describe Insika::Refinement::Budget do
  it "is unlimited when no ceiling is configured, so behaviour is unchanged" do
    budget = described_class.new
    budget.spend(10_000_000)

    expect(budget).not_to be_limited
    expect(budget).not_to be_exhausted
    expect(budget.remaining).to be_nil
  end

  it "is exhausted once the spend reaches the ceiling" do
    budget = described_class.new(tokens: 100)
    budget.spend(60)
    expect(budget).not_to be_exhausted
    expect(budget.remaining).to eq(40)

    budget.spend(40)
    expect(budget).to be_exhausted
    expect(budget.remaining).to eq(0)
  end

  # The honesty knob. A provider that reports no usage makes a leg INVISIBLE to the
  # ceiling; recording it as 0 would leave the budget at "nothing spent" forever
  # while real money went out. Counted separately and shown, never folded into 0.
  it "tallies unmetered legs instead of counting them as free" do
    budget = described_class.new(tokens: 100)
    budget.spend(nil)
    budget.spend(0)
    budget.spend(10)

    expect(budget.to_h).to eq("tokens" => 100, "spent" => 10, "cached" => 0, "unmetered" => 2)
    expect(budget).not_to be_exhausted
  end
end

RSpec.describe Insika::Refinement::Panel do
  BODY = "# Tools\n\nUse shipping_quote to quote freight.\n#{"Be brief and warm.\n" * 30}"

  let(:contents) { { "TOOLS.md" => BODY } }
  let(:allowlist) { ["TOOLS.md"] }
  let(:findings) { [{ "kind" => "tool_error", "count" => 4, "title" => "shipping_quote failed" }] }

  # A proposer that answers with a fixed candidate (or raises), without a provider.
  def proposer(model, edits: [], tokens: nil, raises: nil, reply: nil)
    body = reply || JSON.generate("rationale" => "because", "edits" => edits)
    Insika::Refinement::Proposer.new(model: model, ask: lambda { |_prompt|
      raise raises if raises

      tokens ? FakeMessage.new(body, tokens) : body
    })
  end

  FakeMessage = Struct.new(:content, :total) do
    def input_tokens = total / 2
    def output_tokens = total - input_tokens
  end

  def edit(after, file: "TOOLS.md", before: "Use shipping_quote to quote freight.")
    [{ "file" => file, "op" => "replace", "before" => before, "after" => after }]
  end

  # Scores by a rule over the candidate's text, so a spec can make one member win.
  class ScoringGate
    attr_reader :scored

    def initialize(&rule)
      @rule = rule
      @scored = []
    end

    def score(agent_id:, candidate:, run_id:, tolerance: nil)
      @scored << candidate
      passed_cases, tokens = @rule.call(candidate)
      Insika::Refinement::Gate::Report.new(
        candidate_id: candidate.id, passed: passed_cases.positive?, reason: nil,
        cases: 3, passed_cases: passed_cases, baseline_cases: 3, regressions: [],
        report: {}, tokens: tokens, cached: nil
      )
    end
  end

  def run_panel(proposers, gate, budget: Insika::Refinement::Budget.new, &block)
    described_class.new(gate: gate, proposers: proposers, budget: budget)
                   .run(agent_id: "support", run_id: "run-1", findings: findings,
                        files: contents, allowlist: allowlist, contents: contents, &block)
  end

  it "gates every candidate and hands the operator the highest-scoring survivor" do
    gate = ScoringGate.new { |c| [c.edits.first.after.include?("CEP") ? 3 : 1, 100] }
    result = run_panel([proposer("a", edits: edit("Quote freight. Ask for the CEP first.")),
                        proposer("b", edits: edit("Quote freight, warmly."))], gate)

    expect(gate.scored.size).to eq(2)
    expect(result.entries.size).to eq(2)
    expect(result.winner.candidate.edits.first.after).to include("CEP")
    expect(result.winner.proposers).to eq(["a"])
  end

  # convergence is a TIE-BREAK, never a substitute for the score. Two models
  # agreeing on wording is weak evidence; a golden case passing is strong evidence.
  it "prefers the better score over the wording two proposers agreed on" do
    agreed = edit("Quote freight, warmly.")
    gate = ScoringGate.new { |c| [c.edits.first.after.include?("CEP") ? 3 : 1, nil] }
    result = run_panel([proposer("a", edits: agreed), proposer("b", edits: agreed),
                        proposer("c", edits: edit("Quote freight. Ask for the CEP first."))], gate)

    expect(result.winner.proposers).to eq(["c"])
  end

  it "breaks a tie by the smaller diff, then by how many proposers converged" do
    two_edits = [{ "file" => "TOOLS.md", "op" => "replace",
                   "before" => "Use shipping_quote to quote freight.", "after" => "One." },
                 { "file" => "TOOLS.md", "op" => "append", "before" => "", "after" => "Two." }]
    gate = ScoringGate.new { |_c| [3, nil] }
    result = run_panel([proposer("a", edits: two_edits),
                        proposer("b", edits: edit("Just one.")),
                        proposer("c", edits: edit("Just one."))], gate)

    expect(result.winner.candidate.edits.size).to eq(1)
    expect(result.winner.proposers).to eq(%w[b c])
    expect(result.winner.converged).to eq(2)
  end

  # Gating an identical edit set twice spends a whole golden replay to learn the same
  # number. The agreement is worth more as a tie-break than as a second row.
  it "gates identical candidates once and records both proposers" do
    same = edit("Ask for the CEP first.")
    gate = ScoringGate.new { |_c| [3, nil] }
    result = run_panel([proposer("a", edits: same), proposer("b", edits: same)], gate)

    expect(gate.scored.size).to eq(1)
    expect(result.entries.size).to eq(1)
    expect(result.entries.first.proposers).to eq(%w[a b])
  end

  # The whole point of asking several models is that one of them being useless is a
  # survivable event.
  it "drops a proposer that answers prose or dies, and keeps the panel" do
    gate = ScoringGate.new { |_c| [3, nil] }
    result = run_panel([proposer("a", reply: "Sure! Here is what I would change:"),
                        proposer("b", edits: edit("Ask for the CEP first.")),
                        proposer("c", raises: RuntimeError.new("502"))], gate)

    expect(result.entries.size).to eq(1)
    expect(result.entries.first.proposers).to eq(["b"])
    expect(result.failed.join).to include("a: Insika::Refinement::Proposer::Unusable")
    expect(result.failed.join).to include("c: RuntimeError: 502")
  end

  it "refuses when every proposer failed, naming each one" do
    gate = ScoringGate.new { |_c| [3, nil] }
    expect {
      run_panel([proposer("a", edits: [], raises: RuntimeError.new("502")),
                 proposer("b", edits: [], raises: RuntimeError.new("timeout"))], gate)
    }.to raise_error(Insika::ValidationError, /a: RuntimeError: 502.*b: RuntimeError: timeout/)
  end

  it "refuses when every edit of every proposal was dropped, with the drop reasons" do
    gate = ScoringGate.new { |_c| [3, nil] }
    expect {
      run_panel([proposer("a", edits: edit("x", before: "text that is not in the file")),
                 proposer("b", edits: edit("y", file: "SECRETS.md"))], gate)
    }.to raise_error(Insika::ValidationError, /stale or invented.*not on the refinement allowlist/m)
  end

  # A budget that silently drops the candidates it could not afford would read as
  # "the panel only had one idea". The refusal is recorded on the entry.
  it "stops gating when the budget is spent and says so on the candidates it skipped" do
    budget = Insika::Refinement::Budget.new(tokens: 500)
    gate = ScoringGate.new { |_c| [3, 400] }
    result = run_panel([proposer("a", edits: edit("First."), tokens: 200),
                        proposer("b", edits: edit("Second.")),
                        proposer("c", edits: edit("Third."))], gate, budget: budget)

    expect(gate.scored.size).to eq(1)
    skipped = result.entries.drop(1)
    expect(skipped.map { |e| e.report.passed }).to eq([false, false])
    expect(skipped.first.report.reason).to include("token budget (500) was spent")
    expect(budget.to_h["spent"]).to eq(600) # 200 proposed + 400 replayed
    expect(budget.to_h["unmetered"]).to eq(2)
  end

  it "yields the built panel before any of it is scored" do
    gate = ScoringGate.new { |_c| [3, nil] }
    seen = nil
    run_panel([proposer("a", edits: edit("First."))], gate) do |entries|
      seen = [entries.size, gate.scored.size]
    end

    expect(seen).to eq([1, 0])
  end

  # A candidate that ARRIVED (Studio form, API client) needs no proposer and costs
  # this run nothing.
  it "gates a supplied candidate without asking any model" do
    gate = ScoringGate.new { |_c| [3, nil] }
    result = described_class.new(gate: gate, proposers: [], budget: Insika::Refinement::Budget.new)
                            .run(agent_id: "support", run_id: "run-1", findings: findings,
                                 files: contents, allowlist: allowlist, contents: contents,
                                 raw: { "proposer" => "operator", "edits" => edit("Ask for the CEP.") })

    expect(result.winner.proposers).to eq(["operator"])
    expect(result.budget.to_h["unmetered"]).to eq(1) # the gate's reply, not a proposal
  end

  it "has no winner when nothing survived, and keeps the entries for the record" do
    gate = ScoringGate.new { |_c| [0, nil] }
    result = run_panel([proposer("a", edits: edit("First.")),
                        proposer("b", edits: edit("Second."))], gate)

    expect(result.winner).to be_nil
    expect(result.entries.size).to eq(2)
    expect(described_class.best_refusal(result.entries).report.cases).to eq(3)
  end
end
