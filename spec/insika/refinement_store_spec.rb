# frozen_string_literal: true

require "spec_helper"

# RFC-0013 phase A: the run record of a refinement (a REPORT — phase A writes no
# edits anywhere).
RSpec.describe Insika::RefinementStore do
  subject(:store) { described_class.new(store: Insika::Stores::Memory.new) }

  let(:finding) do
    { kind: :tool_error, key: "tool_error:shipping_quote:missing cep", title: "shipping_quote failed",
      count: 4, severity: 3, sessions: %w[s1 s2], detail: nil }
  end

  it "create opens a run in :collecting and records the window as data" do
    run = store.create(agent_id: "bia", window: { last_sessions: 50 })

    expect(run.status).to eq(:collecting)
    expect(run.agent_id).to eq("bia")
    expect(run.window).to eq("last_sessions" => 50) # symbols normalized on write
    expect(run.findings).to eq([])
    expect(run).not_to be_terminal
  end

  it "complete stores the findings and closes as :completed" do
    run = store.create(agent_id: "bia")
    done = store.complete(run.id, findings: [finding], excluded: 12)

    expect(done.status).to eq(:completed)
    expect(done.excluded).to eq(12) # what the window dropped is part of the record
    expect(done.findings_count).to eq(1)
    expect(done.findings.first["kind"]).to eq("tool_error")
    expect(done.finished_at).not_to be_nil
    expect(store.find(run.id).status).to eq(:completed)
  end

  it "an empty report closes as :no_findings — 'we looked and it was clean' is an answer" do
    run = store.create(agent_id: "bia")
    expect(store.complete(run.id, findings: []).status).to eq(:no_findings)
  end

  it "fail records the error" do
    run = store.create(agent_id: "bia")
    failed = store.fail(run.id, error: "boom")

    expect(failed.status).to eq(:failed)
    expect(failed.error).to eq("boom")
  end

  it "a terminal run never closes twice (a double close is a bug, not a no-op)" do
    run = store.create(agent_id: "bia")
    store.complete(run.id, findings: [])

    expect { store.complete(run.id, findings: [finding]) }.to raise_error(ArgumentError, /already no_findings/)
    expect { store.fail(run.id, error: "x") }.to raise_error(ArgumentError, /already no_findings/)
  end

  it "for_agent returns that agent's runs most recent first, capped" do
    a1 = store.create(agent_id: "bia", at: "2026-08-01T00:00:00Z")
    a2 = store.create(agent_id: "bia", at: "2026-08-02T00:00:00Z")
    other = store.create(agent_id: "chef", at: "2026-08-03T00:00:00Z")

    expect(store.for_agent("bia").map(&:id)).to eq([a2.id, a1.id])
    expect(store.for_agent("bia", limit: 1).map(&:id)).to eq([a2.id])
    expect(store.for_agent("chef").map(&:id)).to eq([other.id])
    expect(store.for_agent("nobody")).to eq([])
  end

  it "latest_for is the agent's most recent run — the anchor of an incremental window" do
    store.create(agent_id: "bia", at: "2026-08-01T00:00:00Z")
    latest = store.create(agent_id: "bia", at: "2026-08-02T00:00:00Z")

    expect(store.latest_for("bia").id).to eq(latest.id)
    expect(store.latest_for("nobody")).to be_nil
  end

  it "recent spans every agent, most recent first" do
    store.create(agent_id: "bia", at: "2026-08-01T00:00:00Z")
    last = store.create(agent_id: "chef", at: "2026-08-05T00:00:00Z")

    expect(store.recent.map(&:agent_id)).to eq(%w[chef bia])
    expect(store.recent(limit: 1).map(&:id)).to eq([last.id])
  end

  it "find on a nonexistent id is nil; closing one is a NotFoundError" do
    expect(store.find("nope")).to be_nil
    expect { store.complete("nope", findings: []) }.to raise_error(Insika::NotFoundError)
  end

  it "rejects an agent id that would break the key layout" do
    expect { store.create(agent_id: "") }.to raise_error(Insika::ValidationError, /required/)
    expect { store.create(agent_id: "a:b") }.to raise_error(Insika::ValidationError, /':'/)
  end

  # RFC-0013 §3.9 (phase D): a run records the whole PANEL, and `candidate`/`gate`
  # are the winner the caller ranked. The store does not rank — it records.
  describe "the panel" do
    def gating_run(candidates)
      run = store.complete(store.create(agent_id: "bia").id, findings: [{ "kind" => "x" }])
      store.gating(run.id, candidates: candidates)
    end

    def report(candidate_id, passed: true)
      { "candidate_id" => candidate_id, "passed" => passed, "reason" => passed ? nil : "regressed",
        "cases" => 3, "passed_cases" => passed ? 3 : 0, "baseline_cases" => 3,
        "regressions" => [], "report" => nil, "tokens" => 120 }
    end

    it "records every candidate before scoring, and claims no winner yet" do
      run = gating_run([{ "id" => "c1", "proposer" => "a", "edits" => [] },
                        { "id" => "c2", "proposer" => "b", "edits" => [] }])

      expect(run.status).to eq(:gating)
      expect(run.panel.map { |e| e["candidate"]["id"] }).to eq(%w[c1 c2])
      expect(run.panel.first["proposers"]).to eq(["a"])
      expect(run.candidate).to be_nil
    end

    it "promotes the candidate the winning report names, and keeps the losers" do
      run = gating_run([{ "id" => "c1", "proposer" => "a", "edits" => [] },
                        { "id" => "c2", "proposer" => "b", "edits" => [] }])
      panel = [{ "candidate" => { "id" => "c1", "proposer" => "a", "edits" => [] },
                 "proposers" => ["a"], "gate" => report("c1", passed: false) },
               { "candidate" => { "id" => "c2", "proposer" => "b", "edits" => [] },
                 "proposers" => ["b"], "gate" => report("c2") }]
      gated = store.gated(run.id, report: report("c2"), panel: panel,
                                  cost: { "tokens" => 1000, "spent" => 240, "unmetered" => 0 })

      expect(gated.status).to eq(:awaiting_approval)
      expect(gated.candidate["proposer"]).to eq("b")
      expect(gated.panel.size).to eq(2)
      expect(gated.cost["spent"]).to eq(240)
    end

    # A phase-C run recorded ONE candidate and no panel; a panel of one is the same
    # shape, so nothing has to branch on which era wrote the record.
    it "wraps a single candidate into the same panel shape" do
      run = gating_run([{ "id" => "c1", "proposer" => "operator", "edits" => [] }])
      gated = store.gated(run.id, report: report("c1"))

      expect(gated.panel.size).to eq(1)
      expect(gated.panel.first["proposers"]).to eq(["operator"])
      expect(gated.candidate["id"]).to eq("c1")
    end

    it "refuses to gate nothing" do
      run = store.complete(store.create(agent_id: "bia").id, findings: [{ "kind" => "x" }])
      expect { store.gating(run.id, candidates: []) }
        .to raise_error(Insika::ValidationError, /candidate is required/)
    end
  end
end
