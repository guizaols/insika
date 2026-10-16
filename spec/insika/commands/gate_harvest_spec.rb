# frozen_string_literal: true

require "spec_helper"

#   — the double gate on ONE candidate, eval first
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
    Insika::Harvest::Criterion.new(rule: rule, path: "deployment/CRITERION.md", sha: "sha256:abc")
  end

  let(:gate) { double("eval gate") }
  let(:conversion_gate) { double("conversion gate") }

  def evals_pass
    allow(gate).to receive(:score) do |agent_id:, skill:, run_id:|
      Insika::Harvest::Gate::Report.new(candidate_id: skill["name"], passed: true, reason: nil,
                                        cases: 7, passed_cases: 7, baseline_cases: 7,
                                        regressions: [], report: { "total" => 7 }, tokens: 1200,
                                        cached: 900, probe: nil)
    end
  end

  def conversion(passed:, reason: nil, current: 0.02)
    Insika::Harvest::ConversionGate::Result.new(passed: passed, reason: reason, metric: "paid",
                                                window: "72h", current: current, baseline: 0.021,
                                                threshold: 0.05,
                                                snapshot_ref: "funnel:platform:store-support:2026-08-16")
  end

  def seed_candidate(origin: ["acme:sess_1"], evidence_turns: [])
    harvest_store.create_candidate(
      run_id: "run-1", agent: "store-support", name: "pix-recovery",
      description: "d", body: "---\nname: pix-recovery\n---\nbody", rationale: "r",
      origin: origin, evidence_turns: evidence_turns, proposer: "utility_model"
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
        report: { "total" => 7 }, tokens: 1200, cached: 900, probe: nil
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

  describe "the probe" do
    let(:session_store) { Insika::SessionStore.new(store: backend) }
    let(:config_store) { Insika::ConfigStore.new(store: backend) }
    let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
    let(:seen) { [] }

    subject(:handler) do
      described_class.new(harvest_store: harvest_store, gate: gate, conversion_gate: conversion_gate,
                          criterion: criterion, event_stream: stream,
                          profiles: profiles, session_store: session_store)
    end

    def seed_profile(probe:)
      profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m", provider: :deepseek,
                                              harvest: { "probe" => probe }))
    end

    def seed_origin(id = "acme:sess_1")
      session_store.create(id: id, vars: { "agent" => "store-support" })
      session_store.append_messages(id, [{ "role" => "user", "content" => "tem pix?" },
                                         { "role" => "assistant", "content" => "não sei" }])
    end

    before do
      allow(gate).to receive(:score) do |agent_id:, skill:, run_id:, probe_cases: []|
        seen << probe_cases
        Insika::Harvest::Gate::Report.new(candidate_id: skill["name"], passed: true, reason: nil,
                                          cases: 1, passed_cases: 1, baseline_cases: 1,
                                          regressions: [], report: {}, tokens: nil, cached: nil, probe: nil)
      end
      allow(conversion_gate).to receive(:call).and_return(conversion(passed: true))
    end

    it "sends the origin customer turns when the agent turned the probe on" do
      seed_profile(probe: { "enabled" => true })
      seed_origin
      c = seed_candidate(evidence_turns: [1])
      handler.call(cmd("candidate_id" => c.id))
      expect(seen).to eq([[["tem pix?"]]])
    end

    it "sends no probe cases when the probe is off" do
      seed_profile(probe: { "enabled" => false })
      seed_origin
      c = seed_candidate
      handler.call(cmd("candidate_id" => c.id))
      expect(seen).to eq([[]])
    end

    it "parks a candidate mined from a multi-session window — the skill's own conversation is unknown" do
      seed_profile(probe: { "enabled" => true })
      seed_origin("acme:sess_1")
      seed_origin("acme:sess_2")
      c = seed_candidate(origin: ["acme:sess_1", "acme:sess_2"])
      result = handler.call(cmd("candidate_id" => c.id))
      expect(result.status).to eq("gated")
      expect(result.eval_gate).to include("passed" => false, "reason" => "probe_ambiguous_origin")
      expect(seen).to be_empty
    end

    it "parks the candidate when the probe is on but the origin is gone" do
      seed_profile(probe: { "enabled" => true })
      c = seed_candidate(origin: ["acme:deleted"])
      result = handler.call(cmd("candidate_id" => c.id))
      expect(result.status).to eq("gated")
      expect(result.eval_gate).to include("passed" => false, "reason" => "probe_no_cases")
      expect(seen).to be_empty
    end
  end
end
