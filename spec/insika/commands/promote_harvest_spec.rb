# frozen_string_literal: true

require "spec_helper"

# RFC-0035 C10 — the human's answer (RFC §4.4). PromoteHarvest is the ONLY
# path that lands a skill: snapshot first, then the two existing write
# commands, then the append-only log row (D8). The conversion ruler is RE-READ
# at the moment the skill lands (D8-bis); a moved criterion is a refusal.
RSpec.describe Insika::Commands::PromoteHarvest do
  subject(:handler) do
    described_class.new(harvest_store: harvest_store, skill_store: skill_store,
                        skill_catalog: skill_catalog, profile_source: profiles,
                        criterion: criterion, conversion_gate: conversion,
                        event_stream: stream, write_skill: write_skill,
                        set_skill_agents: set_skill_agents)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:skill_catalog) { Insika::SkillCatalog.new([], store: skill_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  let(:conversion) { double("conversion gate") }

  let(:criterion) do
    rule = Insika::Harvest::Criterion::Rule.new(version: 1, metric: "paid", window: "72h",
                                                threshold: 0.05, min_span: "28d")
    Insika::Harvest::Criterion.new(rule: rule, path: "deployment/CRITERION.md", sha: "sha256:abc")
  end

  let(:write_skill) do
    Insika::Commands::WriteSkill.new(skill_store: skill_store, skill_catalog: skill_catalog,
                                     event_stream: stream)
  end
  let(:set_skill_agents) do
    Insika::Commands::SetSkillAgents.new(profile_source: profiles, event_stream: stream)
  end

  let(:pass) do
    Insika::Harvest::ConversionGate::Result.new(passed: true, reason: nil, metric: "paid",
                                                window: "72h", current: 0.021, baseline: 0.02,
                                                threshold: 0.05,
                                                snapshot_ref: "funnel:platform:store-support:2026-08-16")
  end

  def seed_awaiting(skills: [])
    profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m", skills: skills))
    cand = harvest_store.create_candidate(
      run_id: "run-1", agent: "store-support", name: "pix-recovery-followup",
      description: "d", body: "---\nname: pix-recovery-followup\ndescription: d\n---\n## Steps\n",
      rationale: "r", origin: ["acme:sess_1"], proposer: "utility_model"
    )
    harvest_store.attach_gate(cand.id, eval_gate: { "passed" => true }, conversion_gate: pass.to_h,
                                        criterion_sha: criterion.sha)
    harvest_store.mark_awaiting(cand.id)
    harvest_store.find_candidate(cand.id)
  end

  def cmd(payload) = Insika::Command.build(:promote_harvest, payload, tenant: "acme")

  before { allow(conversion).to receive(:call).and_return(pass) }

  it "a happy approval: snapshot recorded, the skill lands in the store's agent scope, the allowlist is enabled, the log row is complete, the candidate is promoted, the event carries ids only" do
    cand = seed_awaiting

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("promoted")
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to include("## Steps")
    expect(profiles.fetch("store-support").skills).to eq(%w[pix-recovery-followup])

    # snapshot-first (D8)
    row = harvest_store.promotions.first
    snap = harvest_store.find_snapshot(row.snapshot_ref)
    expect(snap.existed).to be(false)
    expect(snap.enabled_for).to eq([])

    expect(row.skill).to eq("pix-recovery-followup")
    expect(row.origin).to eq(%w[acme:sess_1])
    expect(row.eval_ref).to eq("cand:#{cand.id}")
    expect(row.conversion_ref).to eq("funnel:platform:store-support:2026-08-16")
    expect(row.approver).to eq("operator")
    expect(row.criterion_sha).to eq("sha256:abc")

    event = events.find { |e| e.type == :skill_promoted }
    expect(event.data).to include(agent: "store-support", skill: "pix-recovery-followup",
                                  candidate_id: cand.id, approver: "operator")
    expect(event.data[:snapshot_ref]).not_to be_nil
    expect(event.data[:promotion_ref]).not_to be_nil
    expect(event.data.to_s).to_not include("## Steps")
  end

it "the snapshot content is the PRE-promotion state — an existing skill keeps its prior bytes" do
      skill_store.write("pix-recovery-followup", "---\nname: pix-recovery-followup\n---\nOLD VALUE\n",
                        agent: "store-support")
      cand = seed_awaiting(skills: %w[pix-recovery-followup])

      handler.call(cmd("candidate_id" => cand.id))

      snap = harvest_store.find_snapshot(harvest_store.promotions.first.snapshot_ref)
      expect(snap.existed).to be(true)
      expect(snap.content).to eq("---\nname: pix-recovery-followup\n---\nOLD VALUE\n")
      expect(snap.enabled_for).to eq(%w[store-support])
    end

    it "promoting for A does NOT disable B, and the rollback restores B (the review fix)" do
      # B (store-support-2) already allows the skill; A (store-support) promotes
      # a homonymous skill.
      profiles.put(Insika::AgentProfile.build(id: "store-support-2", model: "m",
                                              skills: %w[pix-recovery-followup greeting]))
      cand = seed_awaiting(skills: [])

      handler.call(cmd("candidate_id" => cand.id))

      expect(profiles.fetch("store-support").skills).to include("pix-recovery-followup")
      expect(profiles.fetch("store-support-2").skills)
        .to eq(%w[pix-recovery-followup greeting]) # B kept it

      snap = harvest_store.find_snapshot(harvest_store.promotions.first.snapshot_ref)
      expect(snap.enabled_for).to eq(%w[store-support-2]) # the pre-promotion holder set

      rollback = Insika::Commands::RollbackHarvest.new(
        harvest_store: harvest_store, skill_store: skill_store, skill_catalog: skill_catalog,
        profile_source: profiles, event_stream: stream
      )
      rollback.call(cmd("snapshot_ref" => snap.id))
      expect(profiles.fetch("store-support").skills).to eq([])
      expect(profiles.fetch("store-support-2").skills)
        .to eq(%w[pix-recovery-followup greeting]) # B restored through the snapshot
    end

  it "D8-bis: a conversion gate that fails AT APPROVE TIME refuses the promotion — the candidate parks with the fresh report, nothing written, no log row" do
    cand = seed_awaiting
    fail_now = Insika::Harvest::ConversionGate::Result.new(passed: false, reason: :conversion_down,
                                                           metric: "paid", window: "72h",
                                                           current: 0.01, baseline: 0.02,
                                                           threshold: 0.05,
                                                           snapshot_ref: "funnel:platform:store-support:2026-08-16")
    allow(conversion).to receive(:call).and_return(fail_now)

    result = handler.call(cmd("candidate_id" => cand.id))

    expect(result.status).to eq("gated")
    expect(result.conversion_gate).to include("passed" => false, "current" => 0.01)
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to be_nil
    expect(harvest_store.promotions).to be_empty
  end

  it "D8-bis: a criterion that changed since boot is a criterion nobody froze -> ValidationError, nothing written" do
    cand = seed_awaiting
    drifted = Insika::Harvest::Criterion.new(rule: criterion.rule, path: criterion.path,
                                             sha: "sha256:different")

    handler_with = described_class.new(harvest_store: harvest_store, skill_store: skill_store,
                                       skill_catalog: skill_catalog, profile_source: profiles,
                                       criterion: drifted, conversion_gate: conversion,
                                       event_stream: stream, write_skill: write_skill,
                                       set_skill_agents: set_skill_agents)
    expect { handler_with.call(cmd("candidate_id" => cand.id)) }
      .to raise_error(Insika::ValidationError, /criterion changed since boot/)
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to be_nil
    expect(harvest_store.promotions).to be_empty
  end

  it "a stale candidate (already promoted) -> the store's ArgumentError" do
    cand = seed_awaiting
    handler.call(cmd("candidate_id" => cand.id))
    expect { handler.call(cmd("candidate_id" => cand.id)) }
      .to raise_error(ArgumentError)
  end

  it "the candidate's criterion_sha was captured at gate time (C9 stamps it) and survives to the row" do
    cand = seed_awaiting
    handler.call(cmd("candidate_id" => cand.id))
    expect(harvest_store.promotions.first.criterion_sha).to eq(cand.criterion_sha)
  end
end