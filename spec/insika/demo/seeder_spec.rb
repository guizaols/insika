# frozen_string_literal: true

require "spec_helper"

# The one path both `insika demo:seed` and the Studio's "Seed demo data"
# button run — see lib/insika/commands/seed_demo_data.rb for the bus adapter.
RSpec.describe Insika::Demo::Seeder do
  subject(:seeder) do
    described_class.new(
      profiles: profiles, store: backend, session_store: session_store, task_store: task_store,
      outcome_store: outcome_store, funnel_store: funnel_store, followup_store: followup_store,
      refinement_store: refinement_store, pending_action_store: pending_action_store,
      proposal_store: proposal_store, memory_store: memory_store,
      golden_store: golden_store, baseline_store: baseline_store, event_stream: event_stream
    )
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:outcome_store) { Insika::OutcomeStore.new(store: backend) }
  let(:funnel_store) { Insika::FunnelStore.new(store: backend) }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:refinement_store) { Insika::RefinementStore.new(store: backend) }
  let(:pending_action_store) { Insika::PendingActionStore.new(store: backend) }
  let(:proposal_store) { Insika::ProposalStore.new(store: backend) }
  let(:memory_store) { Insika::MemoryStore.new(store: backend) }
  let(:golden_store) { Insika::GoldenStore.new(config_store: config_store) }
  let(:baseline_store) { Insika::BaselineStore.new(config_store: config_store) }
  let(:event_stream) { Insika::EventStream.new }

  it "provisions the demo agent with a funnel and a follow-up policy declared" do
    seeder.seed!

    profile = profiles.fetch(Insika::Demo::AGENT_ID)
    expect(profile).not_to be_nil
    expect(Insika::FunnelDeclaration.parse(profile.funnel)).not_to be_nil
    expect(Insika::FollowupPolicy.parse(profile.followup)).not_to be_nil
  end

  it "folds the seeded outcomes into a funnel with a frozen baseline" do
    seeder.seed!

    days = funnel_store.days(tenant: nil, agent: Insika::Demo::AGENT_ID)
    expect(days.size).to be >= 28 # the freeze command's own minimum span

    baseline = funnel_store.baseline(tenant: nil, agent: Insika::Demo::AGENT_ID)
    expect(baseline).not_to be_nil
    expect(baseline["primary"]).to eq("purchased")
  end

  it "writes one follow-up in each of the four states" do
    seeder.seed!

    records = followup_store.for_agent(tenant: nil, agent: Insika::Demo::AGENT_ID)
    expect(records.size).to eq(5)
    expect(records.map(&:status).tally).to eq(
      "pending" => 1, "fired" => 2, "cancelled" => 1, "blocked" => 1
    )
  end

  it "writes refinement runs across the lifecycle" do
    seeder.seed!

    runs = refinement_store.for_agent(Insika::Demo::AGENT_ID)
    expect(runs.size).to eq(4)
    expect(runs.map(&:status)).to contain_exactly(:awaiting_approval, :applied, :rejected, :no_findings)
  end

  it "writes two pending approvals and one resolved, each with a real task" do
    seeder.seed!

    open = pending_action_store.all_open
    expect(open.size).to eq(2)
    open.each { |pa| expect(task_store.find(pa.task_id)).not_to be_nil }
  end

  it "writes distillation proposals and mirrors the approved one into memory" do
    seeder.seed!

    expect(proposal_store.pending(limit: 10).size).to eq(1)
    resolved = proposal_store.resolved(limit: 10)
    expect(resolved.map(&:status)).to contain_exactly("approved", "rejected")

    approved = resolved.find { |p| p.status == "approved" }
    fact = memory_store.get_fact(tenant: nil, customer: approved.customer, key: approved.key)
    expect(fact&.value).to eq(approved.value)
  end

  it "imports the golden set and records a mixed-result baseline" do
    seeder.seed!

    ids = golden_store.for_agent(Insika::Demo::AGENT_ID).map(&:id)
    expect(ids.size).to eq(Insika::Demo::GOLDEN_CASES.size)

    baseline = baseline_store.get(Insika::Demo::AGENT_ID)
    expect(baseline["cases"].keys).to match_array(ids)
    expect(baseline["cases"].values.map { |c| c["pass"] }).to include(false)
  end

  it "returns per-area counts on success" do
    result = seeder.seed!

    expect(result).to include(seeded: true, agent: Insika::Demo::AGENT_ID)
    expect(result[:counts].keys).to contain_exactly(
      :funnel_outcomes, :followups, :refinement_runs, :approvals,
      :distillation_proposals, :golden_cases
    )
  end

  it "is a no-op on a second call without force" do
    seeder.seed!
    result = seeder.seed!(force: false)

    expect(result).to eq(seeded: false, reason: "already_seeded", agent: Insika::Demo::AGENT_ID)
    expect(followup_store.for_agent(tenant: nil, agent: Insika::Demo::AGENT_ID).size).to eq(5)
  end

  it "force re-seeds: the agent stays exactly one record, and the fold stays exact" do
    seeder.seed!
    result = seeder.seed!(force: true)

    expect(result[:seeded]).to be(true)
    expect(profiles.all.count { |p| p.id == Insika::Demo::AGENT_ID }).to eq(1)
    # recompute wipes its own pair's day cells and rebuilds from EVERY outcome
    # record on the pair (two batches' worth, by now) — never a cursor miss or
    # a double-count: the folded total must equal the raw outcome count.
    raw_purchased = outcome_store.for_pair(tenant: nil, agent: Insika::Demo::AGENT_ID)
                                 .count { |r| r.outcome == "purchased" }
    days = funnel_store.days(tenant: nil, agent: Insika::Demo::AGENT_ID)
    folded_purchased = days.values.sum { |c| c["purchased"].to_i }
    expect(folded_purchased).to eq(raw_purchased)
  end

  it "never leaves a seeded task in a non-terminal status (boot recovery must find nothing to do)" do
    seeder.seed!

    task_store.each_id.each do |id|
      expect(%i[completed failed cancelled]).to include(task_store.find(id).status)
    end
  end
end
