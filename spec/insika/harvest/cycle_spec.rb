# frozen_string_literal: true

require "spec_helper"

#   — the full cycle once, end to end (the 0.6 exit criterion):
# mine -> gate -> approve -> promote -> rollback, over the REAL commands and
# stores, with the double gate stubbed only at the provider boundary (the
# eval gate's replay and the conversion gate's fold read). The drill spec's
# acceptance: the store + profile are byte-identical to the pre-promotion
# state when the loop is done.
RSpec.describe "the gated harvest, full cycle " do
  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:profiles) { Insika::StoredProfileSource.new(config_store: config_store) }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:skill_store) { Insika::SkillStore.new(config_store: config_store) }
  let(:skill_catalog) { Insika::SkillCatalog.new([], store: skill_store) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  CRITERION_SOURCE = <<~MD
    # criterion (spec fixture)

    ```yaml
    version: 1
    metric: primary
    window: 72h
    threshold: 0.05
    min_span: 28d
    ```
  MD

  NEGATIVE_SOURCE = <<~MD
    # negative list (spec fixture)

    ## Restrictions

    - `no-competitor-prices` — "concorrente" — never mention competitors or their prices
    - `no-competitor-store` — "outra loja" — never steer the customer to another store
    - `no-refund-promise` — /nao devolvemos/i — the refund policy is the human's answer, never a skill's
    - `no-delivery-promise` — "garantimos a entrega" — delivery promises are the human's call
  MD

  let(:criterion) do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CRITERION.md")
      File.write(path, CRITERION_SOURCE)
      Insika::Harvest::Criterion.load(path)
    end
  end
  let(:negative) do
    Insika::Harvest::NegativeList.parse(NEGATIVE_SOURCE)
  end

  def profile_with_harvest
    Insika::AgentProfile.build(
      id: "store-support", model: "m", skills: %w[greeting],
      harvest: { "enabled" => true, "min_messages" => 2,
                 "miner" => { "model" => "deepseek-v4-flash" } },
      grounding: { "mode" => "enforce", "matcher" => { "sku" => '\bSKU\d{4}\b' } },
      funnel: { "stages" => %w[greeted paid], "advance_on" => { "pix_paid" => "paid" },
                "primary" => "paid", "attribution_window" => "72h" }
    )
  end

  def seed_conversation(id: "acme:sess_1", evidence: %w[SKU0001])
    sessions.create(id: id, vars: { "agent" => "store-support", "customer" => "c-1" })
    sessions.append_messages(id, { "role" => "user", "content" => "oi, meu pix não caiu" })
    sessions.append_messages(id, { "role" => "assistant", "content" => "deixa eu ver o pedido SKU0001" })
    record = sessions.find(id).to_h.merge("updated_at" => "2026-08-10T00:00:00Z")
    record["evidence"] = { "ids" => evidence, "ungrounded" => 0 }
    backend.set("sessions", "session:#{id}", record)
    tasks.create(command: Insika::Command.build(:send_message, {
                                                  "agent" => "store-support", "session_id" => id
                                                }),
                 session_id: id, id: "acme:task_#{SecureRandom.hex(4)}",
                 at: "2026-08-10T00:00:00Z")
  end

  # The miner is stubbed at the PROVIDER boundary (a fake ask); the gate's
  # replay transport likewise — everything else is the real wiring.
  let(:miner) do
    Insika::Harvest::Miner.new(
      ask: lambda { |_prompt|
        JSON.dump([{ "name" => "pix-recovery-followup",
                     "description" => "return when a PIX payment is pending",
                     "body" => "## Steps\n1. Ask for the confirmation of SKU0001.",
                     "triggers" => %w[pix pagamento] }])
      },
      model: "deepseek-v4-flash"
    )
  end
  let(:miner_factory) do
  Class.new do
    def initialize(m) = (@m = m)
    def call(_config) = @m
  end.new(miner)
end
  let(:gate) do
    double("eval gate").tap do |g|
      allow(g).to receive(:score) do |agent_id:, skill:, run_id:|
        Insika::Harvest::Gate::Report.new(candidate_id: skill["name"], passed: true, reason: nil,
                                          cases: 1, passed_cases: 1, baseline_cases: 1,
                                          regressions: [], report: { "total" => 1 }, tokens: 100,
                                          cached: 50)
      end
    end
  end

  it "mine -> gate -> promote -> rollback leaves the store + profile byte-identical (the drill)" do
    profiles.put(profile_with_harvest)
    # the eval surface + the frozen ruler the gates read
    goldens = Insika::GoldenStore.new(config_store: config_store)
    goldens.write({ "id" => "pix", "agent" => "store-support",
                    "turns" => [{ "user" => "oi" }],
                    "expect" => { "tools_called" => [] } })
    baselines = Insika::BaselineStore.new(config_store: config_store)
    baselines.put("store-support", { "cases" => { "pix" => { "pass" => true, "score" => nil } } })
    funnel = Insika::FunnelStore.new(store: backend)
    funnel.set_baseline(tenant: "acme", agent: "store-support",
                        record: { "from" => "2026-07-01", "to" => "2026-08-01",
                                  "stages" => { "greeted" => 100, "paid" => 50 },
                                  "primary" => "paid", "primary_count" => 50,
                                  "conversion" => 0.5, "window" => "72h",
                                  "frozen_at" => "2026-08-01T00:00:00Z" })
    # seed day cells so the conversion gate's fold window has data
    funnel.add(tenant: "acme", agent: "store-support", at: Time.now.utc - 86_400,
               counts: { "paid" => 25, "greeted" => 50 })
    funnel.add(tenant: "acme", agent: "store-support", at: Time.now.utc,
               counts: { "paid" => 25, "greeted" => 50 })

    run_harvest = Insika::Commands::RunHarvest.new(
      profiles: profiles, harvest_store: harvest_store, session_store: sessions,
      task_store: tasks, skill_store: skill_store, negative_list: negative,
      miner_factory: miner_factory, event_stream: stream
    )
    conversion = Insika::Harvest::ConversionGate.new(funnel_store: funnel, criterion: criterion)

    seed_conversation

    # ---- MINE ----
    mined = run_harvest.call(Insika::Command.build(:run_harvest,
                                                   { "agent" => "store-support", "last_sessions" => 5 }))
    expect(mined[:candidates]).to eq(1)
    cand = harvest_store.candidates(agent_id: "store-support").first
    expect(cand.name).to eq("pix-recovery-followup")
    expect(cand.origin).to eq(%w[acme:sess_1])

    # ---- GATE (the double gate: eval replay stubbed at the provider) ----
    gate_harvest = Insika::Commands::GateHarvest.new(harvest_store: harvest_store, gate: gate,
                                                     conversion_gate: conversion, criterion: criterion,
                                                     event_stream: stream)
    gated = gate_harvest.call(Insika::Command.build(:gate_harvest, { "candidate_id" => cand.id },
                                                    tenant: "acme"))
    expect(gated.status).to eq("awaiting_approval")
    expect(gated.eval_gate["passed"]).to be(true)
    expect(gated.conversion_gate["passed"]).to be(true)
    expect(gated.criterion_sha).to eq(criterion.sha)

    # ---- APPROVE + PROMOTE ----
    # the drill's baseline: the pre-promotion state, captured BEFORE the writes
    before_store = skill_store.all(agent: "store-support")
    before_skills = profiles.fetch("store-support").skills
    promote_harvest = Insika::Commands::PromoteHarvest.new(
      harvest_store: harvest_store, skill_store: skill_store, skill_catalog: skill_catalog,
      profile_source: profiles, criterion: criterion, conversion_gate: conversion,
      event_stream: stream
    )
    promoted = promote_harvest.call(Insika::Command.build(:promote_harvest,
                                                          { "candidate_id" => cand.id, "operator" => "studio" },
                                                          tenant: "acme"))
    expect(promoted.status).to eq("promoted")
    expect(skill_store.get("pix-recovery-followup", agent: "store-support")).to include("## Steps")
    expect(profiles.fetch("store-support").skills).to include("pix-recovery-followup")
    promotion = harvest_store.promotions.first
    expect(promotion.approver).to eq("studio")
    expect(promotion.criterion_sha).to eq(criterion.sha)
    expect(events.map(&:type)).to include(:skill_promoted)

    # ---- ROLLBACK (the drill's acceptance: byte-identical) ----
    rollback_harvest = Insika::Commands::RollbackHarvest.new(
      harvest_store: harvest_store, skill_store: skill_store, skill_catalog: skill_catalog,
      profile_source: profiles, event_stream: stream
    )
    rolled = rollback_harvest.call(Insika::Command.build(:rollback_harvest,
                                                         { "snapshot_ref" => promotion.snapshot_ref,
                                                           "operator" => "studio", "reason" => "drill" }))
    expect(rolled.rolled_back_at).to_not be_nil

    expect(skill_store.all(agent: "store-support")).to eq(before_store)
    expect(profiles.fetch("store-support").skills).to eq(before_skills)
    # the log tells the whole story: one row, stamped
    expect(harvest_store.promotions.first.rolled_back_at).to_not be_nil
  end
end