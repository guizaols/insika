# frozen_string_literal: true

require "spec_helper"

#   — the snapshot restored. RollbackHarvest restores the
# pre-promotion state deterministically; the "rehearsed once end-to-end"
# acceptance (the drill) is the full promote -> rollback cycle
# leaving the store + profile byte-identical.
RSpec.describe Insika::Commands::RollbackHarvest do
  subject(:handler) do
    described_class.new(harvest_store: harvest_store, skill_store: skill_store,
                        skill_catalog: skill_catalog, profile_source: profiles,
                        event_stream: stream)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:skill_catalog) { Insika::SkillCatalog.new([], store: skill_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }

  def cmd(payload) = Insika::Command.build(:rollback_harvest, payload, tenant: "acme")

  # Promote a candidate end to end (the real PromoteHarvest), returning the
  # promotion row.
  def promote!(name: "pix-recovery-followup", skills: %w[greeting], existing: nil)
    profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m", skills: skills))
    skill_store.write(name, existing, agent: "store-support") if existing
    cand = harvest_store.create_candidate(
      run_id: "run-1", agent: "store-support", name: name, description: "d",
      body: "---\nname: #{name}\ndescription: d\n---\n## NEW BODY\n",
      rationale: "r", origin: ["acme:sess_1"], proposer: "utility_model"
    )
    harvest_store.attach_gate(cand.id,
                              eval_gate: { "passed" => true },
                              conversion_gate: { "passed" => true, "snapshot_ref" => "funnel:platform:store-support:2026-08-16" },
                              criterion_sha: "sha256:abc")
    harvest_store.mark_awaiting(cand.id)

    criterion = Insika::Harvest::Criterion.new(
      rule: Insika::Harvest::Criterion::Rule.new(version: 1, metric: "paid", window: "72h",
                                                 threshold: 0.05, min_span: "28d"),
      path: "deployment/CRITERION.md", sha: "sha256:abc"
    )
    conversion = double("conversion gate")
    allow(conversion).to receive(:call).and_return(
      Insika::Harvest::ConversionGate::Result.new(passed: true, reason: nil, metric: "paid",
                                                  window: "72h", current: 1.0, baseline: 1.0,
                                                  threshold: 0.05,
                                                  snapshot_ref: "funnel:platform:store-support:2026-08-16")
    )
    promoter = Insika::Commands::PromoteHarvest.new(
      harvest_store: harvest_store, skill_store: skill_store, skill_catalog: skill_catalog,
      profile_source: profiles, criterion: criterion, conversion_gate: conversion,
      event_stream: stream
    )
    promoter.call(Insika::Command.build(:promote_harvest, { "candidate_id" => cand.id }, tenant: "acme"))
    harvest_store.promotions.first
  end

  it "rollback of a CREATED skill -> the skill is gone, the allowlist restored to the snapshot's enabled_for, the log row stamped rolled_back_at" do
    promotion = promote!
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to include("## NEW BODY")
    expect(profiles.fetch("store-support").skills).to eq(%w[greeting pix-recovery-followup])

    result = handler.call(cmd("snapshot_ref" => promotion.snapshot_ref,
                              "operator" => "studio", "reason" => "audit"))

    expect(result.rolled_back_at).not_to be_nil
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to be_nil
    expect(profiles.fetch("store-support").skills).to eq(%w[greeting])
    event = events.find { |e| e.type == :skill_rolled_back }
    expect(event.data).to include(snapshot_ref: promotion.snapshot_ref,
                                  skill: "pix-recovery-followup", operator: "studio")
  end

  it "rollback of an OVERWRITTEN skill -> the pre-promotion bytes are back, byte-identical, allowlist restored" do
    prior = "---\nname: pix-recovery-followup\n---\nORIGINAL BODY\n"
    promotion = promote!(existing: prior, skills: %w[greeting pix-recovery-followup])
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to include("## NEW BODY")

    handler.call(cmd("snapshot_ref" => promotion.snapshot_ref))

    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to eq(prior)
    expect(profiles.fetch("store-support").skills).to eq(%w[greeting pix-recovery-followup])
  end

  it "the full promote -> rollback cycle leaves the store + profile byte-identical to the pre-promotion state (the drill)" do
    profiles.put(Insika::AgentProfile.build(id: "store-support", model: "m", skills: %w[greeting]))
    prior = "---\nname: pix-recovery-followup\n---\nORIGINAL BODY\n"
    skill_store.write("pix-recovery-followup", prior, agent: "store-support")

    before_store = skill_store.all(agent: "store-support")
    before_skills = profiles.fetch("store-support").skills

    promotion = promote!(existing: prior, skills: %w[greeting])
    handler.call(cmd("snapshot_ref" => promotion.snapshot_ref))

    expect(skill_store.all(agent: "store-support")).to eq(before_store)
    expect(profiles.fetch("store-support").skills).to eq(before_skills)
  end

  it "missing snapshot_ref -> ValidationError; an unknown snapshot -> NotFoundError; a bare record without a promotion row still rolls back (crash between the writes and the append)" do
    expect { handler.call(cmd({})) }.to raise_error(Insika::ValidationError)
    expect { handler.call(cmd("snapshot_ref" => "nope")) }.to raise_error(Insika::NotFoundError)

    snap = harvest_store.create_snapshot(agent: "store-support", skill: "orphan",
                                         content: nil, existed: false, enabled_for: [])
    result = handler.call(cmd("snapshot_ref" => snap.id))
    expect(result).to be_a(Insika::HarvestStore::Promotion).or be_nil
    expect(harvest_store.promotions).to be_empty
  end
end