# frozen_string_literal: true

require "spec_helper"

# RFC-0035 C9 — the double gate on ONE candidate (D7 + D6), eval first
# (expensive — replay), conversion second (cheap — a fold read). Both passed ->
# awaiting_approval; either failed -> rejected with the reason; a conversion
# REFUSAL (missing data) PARKS the candidate at gated with the named reason —
# the page shows the ruler's hole, nothing is lost. E3 closes here.
RSpec.describe Insika::Commands::GateHarvest do
  subject(:handler) do
    described_class.new(harvest_store: harvest_store, gate: gate, conversion_gate: conversion_gate,
                        criterion: criterion, event_stream: stream)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  let(:criterion) do
    rule = Insika::Harvest::Criterion::Rule.new(version: 1, metric: "paid", window: "72h",
                                                threshold: 0.05, min_span: "28d")
    Insika::Harvest::Criterion.new(rule: rule, path: "harvest/CRITERION.md", sha: "sha256:abc")
  end

  let(:gate) { double("eval gate") }
  let(:conversion_gate) { double("conversion gate") }

  def evals_pass
    allow(gate).to receive(:score) do |agent_id:, skill:, run_id:|
      Insika::Harvest::Gate::Report.new(candidate_id: skill["name"], passed: true, reason: nil,
                                        cases: 7, passed_cases: 7, baseline_cases: 7,
                                        regressions: [], report: { "total" => 7 }, tokens: 1200,
                                        cached: 900)
    end
  end

  def conversion(passed:, reason: nil, current: 0.02)
    Insika::Harvest::ConversionGate::Result.new(passed: passed, reason: reason, metric: "paid",
                                                window: "72h", current: current, baseline: 0.021,
                                                threshold: 0.05,
                                                snapshot_ref: "funnel:platform:store-support:2026-08-16")
  end

  def seed_candidate
    harvest_store.create_candidate(
      run_id: "run-1", agent: "store-support", name: "pix-recovery",
      description: "d", body: "---\nname: pix-recovery\n---\nbody", rationale: "r",
      origin: ["acme:sess_1"], proposer: "utility_model"
    )
  end

  def cmd(payload) = Insika::Command.build(:gate_harvest, payload, tenant: "acme")

  it "both gates pass -> awaiting_approval with both reports + the criterion sha, event carries verdicts" do
    evals_pass
    allow(conversion_gate).to receive(:call).and_return(conversion(passed: true))
    cand = seed_candidate

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("awaiting_approval")
    expect(result.eval_gate).to include("passed" => true, "cases" => 7)
    expect(result.conversion_gate).to include("passed" => true, "current" => 0.02)
    expect(result.criterion_sha).to eq("sha256:abc")

    event = events.find { |e| e.type == :harvest_gated }
    expect(event.data).to include(candidate_id: cand.id, agent: "store-support",
                                  eval_passed: true, conversion_passed: true, reason: nil)
  end

  it "E3 END-TO-END: a candidate that improves eval but tanks the ledger metric is REJECTED (conversion fail with numbers)" do
    evals_pass
    allow(conversion_gate).to receive(:call).and_return(conversion(passed: false, reason: :conversion_down, current: 0.015))
    cand = seed_candidate

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("rejected")
    expect(result.decision).to include("by" => "gate")
    expect(result.conversion_gate["current"]).to eq(0.015)
    expect(result.eval_gate["passed"]).to be(true)
    event = events.find { |e| e.type == :harvest_gated }
    expect(event.data).to include(eval_passed: true, conversion_passed: false, reason: :conversion_down)
  end

  it "a known-worse candidate is rejected by the eval gate (regressions)" do
    allow(gate).to receive(:score) do |agent_id:, skill:, run_id:|
      Insika::Harvest::Gate::Report.new(
        candidate_id: skill["name"], passed: false,
        reason: "1 regression(s): quotes-freight (pass→fail)", cases: 7, passed_cases: 6,
        baseline_cases: 7,
        regressions: [{ "id" => "quotes-freight", "kind" => "pass→fail", "detail" => nil }],
        report: { "total" => 7 }, tokens: 1200, cached: 900
      )
    end
    allow(conversion_gate).to receive(:call).and_return(conversion(passed: true))
    cand = seed_candidate

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("rejected")
    expect(result.eval_gate["passed"]).to be(false)
    expect(result.decision["note"]).to match(/regression/)
  end

  it "a conversion REFUSAL parks the candidate at gated with the named reason — NOT rejected, NOT awaiting" do
    evals_pass
    allow(conversion_gate).to receive(:call).and_return(conversion(passed: false, reason: :no_frozen_baseline))
    cand = seed_candidate

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("gated")
    expect(result.eval_gate["passed"]).to be(true)
    expect(result.conversion_gate["reason"]).to eq("no_frozen_baseline")
  end

  it "the mining budget is read at gate time — a run that spent its cap refuses the expensive replay (the review fix)" do
    allow(gate).to receive(:score)
    run = harvest_store.create_run(agent_id: "store-support", budget: { "tokens" => 100 })
    harvest_store.complete_run(run.id, candidates: 1, cost: { "spent" => 100 })
    cand = harvest_store.create_candidate(
      run_id: run.id, agent: "store-support", name: "pix", description: "d",
      body: "b", rationale: "r", origin: ["acme:sess_1"], proposer: "utility_model"
    )

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("gated")
    expect(result.eval_gate).to include("passed" => false, "reason" => "budget_exceeded")
    expect(gate).to_not have_received(:score)
  end

  it "a double gate is the loudly spelled bug (the store's ArgumentError)" do
    evals_pass
    allow(conversion_gate).to receive(:call).and_return(conversion(passed: true))
    cand = seed_candidate
    handler.call(cmd("candidate_id" => cand.id))
    expect { handler.call(cmd("candidate_id" => cand.id)) }
      .to raise_error(ArgumentError, /expected pending/)
  end

  it "a missing candidate_id -> ValidationError; an unknown one -> NotFoundError" do
    expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError)
    expect { handler.call(cmd("candidate_id" => "nope")) }.to raise_error(Insika::NotFoundError)
  end
end