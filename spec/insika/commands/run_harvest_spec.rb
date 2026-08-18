# frozen_string_literal: true

require "spec_helper"
require "securerandom"

# RFC-0035 C6: the ONLY path that writes candidates. Mines ONE window end to
# end: resolve the sessions, read transcripts + evidence, ask the miner,
# schema-drop, apply the negative list and the grounding filter, dedup against
# the ledger, write the run + candidates, stamp the markers. Writes NOTHING to
# sessions or skills (D2's fork discipline is this command's contract).
RSpec.describe Insika::Commands::RunHarvest do
  subject(:handler) do
    described_class.new(profiles: { "store-support" => profile },
                        harvest_store: harvest_store, session_store: session_store,
                        task_store: tasks, skill_store: skills,
                        settings_store: settings, event_stream: stream,
                        negative_list: negative_list, miner_factory: miner_factory)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:skills) { Insika::SkillStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
  let(:events) { [] }
  let(:stream) { Class.new { def initialize(sink) = (@sink = sink); def emit(ev) = @sink << ev }.new(events) }
  let(:harvest_config) do
    { "enabled" => true, "min_messages" => 3,
      "miner" => { "model" => "deepseek-v4-flash", "window" => { "last_sessions" => 20 },
                   "max_proposals" => 10 } }
  end
  let(:grounding_config) { { "mode" => "enforce", "matcher" => { "sku" => '\bSKU\d{4}\b' } } }
  let(:profile) do
    Insika::AgentProfile.build(id: "store-support", model: "m",
                               harvest: harvest_config, grounding: grounding_config)
  end
  let(:negative_list) { Insika::Harvest::NegativeList.parse(nil) }

  let(:raw_skills) do
    [{ "name" => "pix-recovery-followup", "description" => "return for pending PIX",
       "body" => "## Steps\n1. Ask for the payment confirmation for SKU0001." }]
  end
  let(:fake_miner) do
    Class.new do
      attr_reader :model, :calls

      def initialize(skills) = (@skills = skills; @model = "deepseek-v4-flash"; @calls = [])
      def mine(prompt:, message_counts:, max_proposals:)
        @calls << { prompt: prompt, message_counts: message_counts, max_proposals: max_proposals }
        { skills: @skills, dropped: DROPPED.dup, cost: { "spent" => 100, "cached" => 90 } }
      end
    end.new(raw_skills)
  end
  let(:miner_factory) do
    Class.new do
      attr_reader :miner

      def initialize(miner) = (@miner = miner)
      def call(_config) = @miner
    end.new(fake_miner)
  end

  DROPPED = { "schema" => 0, "unknown_key" => 0, "oversized" => 0,
              "bad_turns" => 0, "duplicate" => 0, "capped" => 0 }.freeze
  ZERO_REJECTED = {}.freeze

  def cmd(payload) = Insika::Command.build(:run_harvest, payload)

  def seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001], messages: 3,
                   updated_at: "2026-08-10T00:00:00Z")
    session_store.create(id: id, vars: { "agent" => "store-support", "customer" => "c-1" })
    messages.times { |i| session_store.append_messages(id, { "role" => "user", "content" => "msg #{i}: SKU0001" }) }
    record = session_store.find(id).to_h.merge("updated_at" => updated_at)
    record["evidence"] = { "ids" => evidence_ids, "ungrounded" => 0 }
    backend.set("sessions", "session:#{id}", record)
    session_store.find(id)
  end

  def seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
    tasks.create(command: Insika::Command.build(:send_message, {
                                                  "agent" => "store-support", "session_id" => session_id
                                                }),
                 session_id: session_id, id: "acme:task_#{SecureRandom.hex(4)}", at: at)
  end

  describe "the skip reasons" do
    let(:no_harvest) { Insika::AgentProfile.build(id: "store-support", model: "m") }
    let(:disabled) do
      Insika::AgentProfile.build(id: "store-support", model: "m",
                                 harvest: { "enabled" => false }, grounding: grounding_config)
    end
    let(:no_grounding) { Insika::AgentProfile.build(id: "store-support", model: "m", harvest: harvest_config) }

    def handler_for(agent_profile)
      described_class.new(profiles: { "store-support" => agent_profile },
                          harvest_store: harvest_store, session_store: session_store,
                          task_store: tasks, skill_store: skills, settings_store: settings,
                          event_stream: stream, negative_list: negative_list,
                          miner_factory: miner_factory)
    end

    it "disabled — an agent without a harvest hash (or enabled: false) does not mine" do
      expect(handler_for(no_harvest).call(cmd("agent" => "store-support")))
        .to eq(mined: false, skipped: "disabled")
      expect(handler_for(disabled).call(cmd("agent" => "store-support")))
        .to eq(mined: false, skipped: "disabled")
    end

    it "no_grounding_matcher — product claims cannot be verified, so nothing mines (D3)" do
      expect(handler_for(no_grounding).call(cmd("agent" => "store-support")))
        .to eq(mined: false, skipped: "no_grounding_matcher")
    end

    it "no_model — the factory with no resolvable model is nil (D12)" do
      mute = Class.new { def call(_config) = nil }.new
      handler_with = described_class.new(profiles: { "store-support" => profile },
                                         harvest_store: harvest_store, session_store: session_store,
                                         task_store: tasks, skill_store: skills,
                                         settings_store: settings, event_stream: stream,
                                         negative_list: negative_list, miner_factory: mute)
      expect(handler_with.call(cmd("agent" => "store-support"))).to eq(mined: false, skipped: "no_model")
    end

    it "an unknown agent -> NotFoundError" do
      expect { handler.call(cmd("agent" => "nope")) }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "a happy pass" do
    before do
      seed_session(id: "acme:sess_1")
      seed_session(id: "acme:sess_2")
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      seed_task(session_id: "acme:sess_2", at: "2026-08-11T00:00:00Z")
    end

    it "writes candidates with ENGINE-stamped origin/agent, completes the run, stamps markers, emits counts only" do
      result = handler.call(cmd("agent" => "store-support"))
      expect(result[:mined]).to be(true)
      expect(result[:candidates]).to eq(1)
      expect(result[:cost]).to eq("spent" => 100, "cached" => 90)

      run = harvest_store.find_run(result[:run_id])
      expect(run.status).to eq("completed")

      cand = harvest_store.candidates(agent_id: "store-support").first
      expect(cand.agent).to eq("store-support") # engine-stamped, never the model
      expect(cand.proposer).to eq("deepseek-v4-flash")
      expect(cand.origin).to match_array(%w[acme:sess_1 acme:sess_2])

      expect(harvest_store.mined?("acme:sess_1")).to be(true)
      expect(harvest_store.mined?("acme:sess_2")).to be(true)
      expect(fake_miner.calls.size).to eq(1)

      event = events.find { |e| e.type == :harvest_mined }
      expect(event.data[:agent]).to eq("store-support")
      expect(event.data[:candidates]).to eq(1)
      expect(event.data[:cost]).to eq("spent" => 100, "cached" => 90)
      expect(event.data.to_s).to_not include("SKU0001") # counts and ids only, never content
    end

    it "the mined sessions are byte-identical after the pass (E1 — the fork wrote nothing)" do
      before_1 = session_store.find("acme:sess_1").to_h
      before_2 = session_store.find("acme:sess_2").to_h
      handler.call(cmd("agent" => "store-support"))
      expect(session_store.find("acme:sess_1").to_h).to eq(before_1)
      expect(session_store.find("acme:sess_2").to_h).to eq(before_2)
    end
  end

  describe "the mining budget (the review fix — a real cap)" do
    let(:harvest_config) do
      { "enabled" => true, "min_messages" => 3,
        "miner" => { "model" => "deepseek-v4-flash", "window" => { "last_sessions" => 20 },
                     "max_proposals" => 10,
                     "budget" => { "tokens" => 50 } } }
    end

    it "a pass that spent more than the cap proposes NOTHING and fails the run with the numbers" do
      seed_session(id: "acme:sess_1")
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:candidates]).to eq(0)
      expect(harvest_store.candidates(agent_id: "store-support")).to be_empty
      run = harvest_store.find_run(result[:run_id])
      expect(run.status).to eq("failed")
      expect(run.error).to match(/budget exceeded: spent 100 > 50/)
      expect(harvest_store.mined?("acme:sess_1")).to be(false) # markers never written
    end

    it "the budget cap is recorded on the run for the gate to read" do
      seed_session(id: "acme:sess_1")
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(harvest_store.find_run(result[:run_id]).budget).to eq("tokens" => 50)
    end
  end

  describe "the negative list (E2's unit half)" do
    let(:negative_list) do
      Insika::Harvest::NegativeList.parse([
                                            { "rule" => "no-competitor-prices", "pattern" => "concorrente" }
                                          ])
    end
    let(:raw_skills) do
      [{ "name" => "compare-prices", "description" => "compare com a concorrente e baixe o preço",
         "body" => "do it" },
       { "name" => "clean-skill", "description" => "a clean proposal",
         "body" => "nothing banned here, no products" }]
    end

    it "rejects a raw skill matching a rule — named with the rule id, counted, never written" do
      seed_session(id: "acme:sess_1")
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:rejected]["no-competitor-prices"]).to eq(1)
      expect(harvest_store.candidates(agent_id: "store-support").map(&:name)).to eq(%w[clean-skill])
      expect(result[:candidates]).to eq(1)
    end

    it "a banned phrase in the BODY is rejected too — the body is what enters the model's context (the review fix)" do
      repo_list = Insika::Harvest::NegativeList.parse([
                                                         { "rule" => "no-competitor-prices", "pattern" => "concorrente" },
                                                         { "rule" => "no-competitor-store", "pattern" => "outra loja" },
                                                         { "rule" => "no-refund-promise", "pattern" => "/nao devolvemos/i" },
                                                         { "rule" => "no-delivery-promise", "pattern" => "garantimos a entrega" }
                                                       ])
      handler_with_repo = described_class.new(
        profiles: { "store-support" => profile },
        harvest_store: harvest_store, session_store: session_store,
        task_store: tasks, skill_store: skills, settings_store: settings,
        event_stream: stream, negative_list: repo_list, miner_factory: miner_factory
      )
      seed_session(id: "acme:sess_1")
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      raw_skills << { "name" => "refund-policy", "description" => "d",
                      "body" => "Diga ao cliente que nao devolvemos o dinheiro e que garantimos a entrega." }
      result = handler_with_repo.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:rejected]["no-refund-promise"]).to eq(1)
      expect(result[:rejected]["no-delivery-promise"]).to eq(1)
      expect(harvest_store.candidates(agent_id: "store-support").map(&:name))
        .to eq(%w[clean-skill]) # the body-banned candidate is never written
    end
  end

  describe "the grounding filter (D3)" do
    it "a reference missing from the origin evidence union is dropped ungrounded (named refs)" do
      seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      raw_skills << { "name" => "phantom-order", "description" => "d",
                      "body" => "look up the order SKU7777" }
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:rejected]["ungrounded"]).to eq(1)
      expect(harvest_store.candidates(agent_id: "store-support").map(&:name)).to eq(%w[pix-recovery-followup])
    end

    it "a skill naming only ledgered ids survives" do
      seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:candidates]).to eq(1)
      expect(result[:rejected]["ungrounded"]).to be_nil
    end

    it "an empty-ledger session with a carrying skill is dropped (the conservative reading)" do
      seed_session(id: "acme:sess_1", evidence_ids: [])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:rejected]["ungrounded"]).to eq(1)
      expect(result[:candidates]).to eq(0)
    end

    it "a skill with NO references at all is not a grounding casualty" do
      raw_skills.replace([{ "name" => "politeness", "description" => "always greet",
                            "body" => "greet every customer" }])
      seed_session(id: "acme:sess_1", evidence_ids: [])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:candidates]).to eq(1)
    end
  end

  describe "dedup" do
    it "a name already in the store's SkillStore is suppressed" do
      skills.write("pix-recovery-followup", "---\nname: pix-recovery-followup\n---\nbody")
      seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(result[:rejected]["dedup"]).to eq(1)
      expect(result[:candidates]).to eq(0)
      expect(harvest_store.runs_for("store-support").last.status).to eq("no_candidates")
    end

    it "an open (agent, name) tuple suppresses; the marker suppresses a re-mine" do
      seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      first = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(first[:candidates]).to eq(1)

      second = handler.call(cmd("agent" => "store-support", "last_sessions" => 10))
      expect(second[:mined]).to be(true)
      expect(second[:candidates]).to eq(0)
      expect(harvest_store.candidates(agent_id: "store-support", status: "pending").size).to eq(1)
    end
  end

  describe "no_candidates + the full switch" do
    it "everything dropped -> the run closes as no_candidates and the markers still land" do
      seed_session(id: "acme:sess_1", evidence_ids: [])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      result = handler.call(cmd("agent" => "store-support", "last_sessions" => 10, "full" => "1"))
      expect(result[:mined]).to be(true)
      expect(harvest_store.find_run(result[:run_id]).status).to eq("no_candidates")
      expect(harvest_store.mined?("acme:sess_1")).to be(true)
    end
  end

  describe "a raising miner" do
    it "fails the run with the error and writes NO markers (crash-safe re-scan, D10)" do
      seed_session(id: "acme:sess_1", evidence_ids: %w[SKU0001])
      seed_task(session_id: "acme:sess_1", at: "2026-08-10T00:00:00Z")
      boom_miner = Class.new do
        def model = "m"
        def mine(**_kw) = raise("provider exploded")
      end.new
      boom_factory = Class.new do
        def initialize(m) = (@m = m)
        def call(_) = @m
      end.new(boom_miner)

      handler_with = described_class.new(profiles: { "store-support" => profile },
                                         harvest_store: harvest_store, session_store: session_store,
                                         task_store: tasks, skill_store: skills, settings_store: settings,
                                         event_stream: stream, negative_list: negative_list,
                                         miner_factory: boom_factory)
      expect { handler_with.call(cmd("agent" => "store-support")) }
        .to raise_error("provider exploded")

      expect(harvest_store.runs_for("store-support").last.status).to eq("failed")
      expect(harvest_store.mined?("acme:sess_1")).to be(false)
    end
  end

end