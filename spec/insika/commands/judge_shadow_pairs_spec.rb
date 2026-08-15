# frozen_string_literal: true

require "spec_helper"

# C7 — turning complete pairs into judged pairs with the judges the operator
# ALREADY configured. Never automatic, never a no-op: a refusal is visible,
# a fake judge is not.
RSpec.describe Insika::Commands::JudgeShadowPairs do
  CRITERION = Insika::Parity::Criterion.load(File.expand_path("../../../evals/PARITY.md", __dir__))

  let(:backend) { Insika::Stores::Memory.new }
  let(:config_store) { Insika::ConfigStore.new(store: backend) }
  let(:settings_store) { Insika::SettingsStore.new(config_store: config_store) }
  let(:pairs) { Insika::ShadowPairStore.new(store: backend) }
  let(:events) { ServerEventStreamDouble.new }
  let(:pairwise) { stub_pairwise }

  # A scripted panel: every pair gets the same verdict, calls are recorded.
  def stub_pairwise(outcome: "better")
    verdict = Insika::Evals::Pairwise::Verdict.new(outcome: outcome, reason: "r",
                                                   vs: "agent", judges: %w[better better better],
                                                   order_dependent: false)
    Object.new.tap do |obj|
      obj.define_singleton_method(:compare_texts) do |**| # **
        verdict
      end
    end
  end

  def command(payload: {})
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([pairwise, %w[m1 m2 m3]])
    described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                        criterion: CRITERION, event_stream: events)
                   .call(Insika::Command.build(:judge_shadow_pairs, payload))
  end

  def plant(id:, status: :complete, agent: "agent-store-ocean-drop", created_at: nil)
    pairs.record_incumbent(id: id, channel: "relay", event_id: id, external_id: "5511",
                           reply: "me passa o número?", at: created_at || Time.now.utc)
    pairs.record_ours(id: id, channel: "relay", agent: agent, session_id: "relay:5511",
                      task_id: "t", event_id: id, inbound: "queria saber do pedido",
                      reply: "já confiro pra você", criterion_sha: CRITERION.sha)
  end

  it "judges every complete pair and writes the panel's verdict with models + judged_at" do
    plant(id: "p1")
    plant(id: "p2")

    result = command
    expect(result[:judged]).to eq(2)
    expect(result[:models]).to eq(%w[m1 m2 m3])

    pair = pairs.find("p1")
    expect(pair.status).to eq(:judged)
    expect(pair.outcome).to eq("better")
    expect(pair.verdict["models"]).to eq(%w[m1 m2 m3])
    expect(pair.verdict["judged_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
  end

  it "grades both halves through the SAME anonymous transcript format" do
    plant(id: "p1")
    seen = []
    spy = Object.new
    spy.define_singleton_method(:compare_texts) do |ours:, theirs:, vs: "agent"|
      seen << [ours, theirs, vs]
      Insika::Evals::Pairwise::Verdict.new(outcome: "better", reason: "r", vs: vs,
                                           judges: [], order_dependent: false)
    end
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([spy, %w[m1 m2 m3]])
    described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                        criterion: CRITERION, event_stream: events)
                   .call(Insika::Command.build(:judge_shadow_pairs, {}))

    ours, theirs, vs = seen.first
    expect(ours).to eq("customer: queria saber do pedido\nassistant: já confiro pra você")
    expect(theirs).to eq("customer: queria saber do pedido\nassistant: me passa o número?")
    expect(vs).to eq("agent")
  end

  it "never sends :silent or :open pairs to the judge" do
    plant(id: "complete")
    pairs.record_incumbent(id: "open", channel: "relay", event_id: "open", external_id: "5511",
                           reply: "r")
    pairs.record_ours(id: "silent", channel: "relay", agent: "a", session_id: "relay:5511",
                      task_id: "t", event_id: "silent", inbound: "oi", reply: "",
                      criterion_sha: CRITERION.sha)
    pairs.record_incumbent(id: "silent", channel: "relay", event_id: "silent", external_id: "5511",
                           reply: "r")

    result = command
    expect(result[:judged]).to eq(1)
    expect(pairs.find("open").status).to eq(:open)
    expect(pairs.find("silent").status).to eq(:silent)
  end

  it "refuses — judging nothing — when no judges are configured" do
    plant(id: "p1")
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return(nil)
    expect do
      described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                          criterion: CRITERION, event_stream: events)
                     .call(Insika::Command.build(:judge_shadow_pairs, {}))
    end.to raise_error(Insika::ValidationError, /no judges/)
    expect(pairs.find("p1").status).to eq(:complete)
  end

  it "refuses when fewer models than the criterion demands are configured" do
    plant(id: "p1")
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([pairwise, %w[m1 m2]])
    expect do
      described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                          criterion: CRITERION, event_stream: events)
                     .call(Insika::Command.build(:judge_shadow_pairs, {}))
    end.to raise_error(Insika::ValidationError, /3 judge|judge model/)
  end

  it "refuses when the SAME model is configured three times — entries are not distinct models" do
    plant(id: "p1")
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([pairwise, %w[m1 m1 m1]])
    expect do
      described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                          criterion: CRITERION, event_stream: events)
                     .call(Insika::Command.build(:judge_shadow_pairs, {}))
    end.to raise_error(Insika::ValidationError, /distinct judge models/)
  end

  it "refuses BEFORE expiring — a bad click must not stamp :incomplete on pairs" do
    stale = Insika::ShadowPairStore.key_for(channel: "relay", external_id: "old", event_id: "e")
    pairs.record_incumbent(id: stale, channel: "relay", event_id: "e", external_id: "old",
                           reply: "r", at: Time.now.utc - 48 * 3600)
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return(nil)
    expect do
      described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                          criterion: CRITERION, event_stream: events)
                     .call(Insika::Command.build(:judge_shadow_pairs, {}))
    end.to raise_error(Insika::ValidationError, /no judges/)
    expect(pairs.find(stale).status).to eq(:open)
  end

  it "a provider error on one pair never aborts the batch (its class is not Insika::Error)" do
    plant(id: "ok")
    plant(id: "boom")
    flaky = Object.new
    calls = 0
    flaky.define_singleton_method(:compare_texts) do |**| # **
      calls += 1
      raise RuntimeError, "provider 502" if calls == 1

      Insika::Evals::Pairwise::Verdict.new(outcome: "better", reason: "r", vs: "agent",
                                           judges: [], order_dependent: false)
    end
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([flaky, %w[m1 m2 m3]])

    result = described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                                 criterion: CRITERION, event_stream: events)
                            .call(Insika::Command.build(:judge_shadow_pairs, {}))
    expect(result[:failed]).to eq(1)
    expect(result[:judged]).to eq(1)
    expect(pairs.find("boom").status).to eq(:complete)
  end

  it "leaves a raising pair :complete and continues the batch" do
    plant(id: "ok")
    plant(id: "boom")
    flaky = Object.new
    calls = 0
    flaky.define_singleton_method(:compare_texts) do |**| # **
      calls += 1
      raise Insika::ValidationError, "boom" if calls == 1

      Insika::Evals::Pairwise::Verdict.new(outcome: "better", reason: "r", vs: "agent",
                                           judges: [], order_dependent: false)
    end
    allow(Insika::Evals::JudgePanel).to receive(:pairwise).and_return([flaky, %w[m1 m2 m3]])

    result = described_class.new(shadow_pairs: pairs, settings_store: settings_store,
                                 criterion: CRITERION, event_stream: events)
                            .call(Insika::Command.build(:judge_shadow_pairs, {}))
    expect(result[:failed]).to eq(1)
    expect(result[:judged]).to eq(1)
    expect(pairs.find("boom").status).to eq(:complete)
  end

  it "honours the limit and a second press picks up where the first stopped" do
    plant(id: "p1")
    plant(id: "p2")
    plant(id: "p3")

    first = command(payload: { limit: 2 })
    expect(first[:judged]).to eq(2)
    expect(first[:skipped]).to eq(1)
    expect(pairs.unjudged.map(&:id)).to eq(%w[p3])

    second = command
    expect(second[:judged]).to eq(1)
    expect(pairs.unjudged).to be_empty
  end

  it "expires stale open pairs first (default 24h, then the payload's knob)" do
    stale = Insika::ShadowPairStore.key_for(channel: "relay", external_id: "old", event_id: "e")
    pairs.record_incumbent(id: stale, channel: "relay", event_id: "e", external_id: "old",
                           reply: "r", at: Time.now.utc - 48 * 3600)

    result = command
    expect(result[:expired]).to eq(1)
    expect(pairs.find(stale).status).to eq(:incomplete)
  end

  it "emits :shadow_judged per pair (metadata only) and a summary" do
    plant(id: "p1")
    command
    judged_events = events.emitted.select { |e| e.type == :shadow_judged }
    expect(judged_events.length).to eq(1)
    expect(judged_events.first.data).to include(pair_id: "p1", outcome: "better")
    expect(events.emitted.map(&:type)).to include(:shadow_judge_batch)
  end
end
