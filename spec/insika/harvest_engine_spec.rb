# frozen_string_literal: true

require "spec_helper"

#   — the tick-driven harvest loop: one pass per claim
# window scans for idle, unmined sessions whose agent declares
# harvest.enabled AND a grounding matcher, and mines them through RunHarvest
# on a worker fiber. The loop-stop (the H-harvest kill) is the profile's
# `enabled: false` — the engine only respects data.
RSpec.describe Insika::HarvestEngine do
  subject(:engine) do
    described_class.new(store: backend, harvest_store: harvest_store, session_store: sessions,
                        runner: runner, window: 300, idle_hours: idle_hours, profiles: profiles)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:harvest_store) { Insika::HarvestStore.new(store: backend) }
  let(:idle_hours) { 24 }
  let(:profiles) do
    { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m",
        harvest: { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 },
        grounding: { "mode" => "enforce", "matcher" => { "sku" => '\bSKU\d{4}\b' } }
      ) }
  end

  let(:calls) { [] }
  let(:runner) do
    Class.new do
      def initialize(calls) = (@calls = calls)
      def call(command)
        @calls << command.payload
        { mined: true, run_id: "run-x" }
      end
    end.new(calls)
  end

  def seed_session(id: "acme:sess_1", agent: "store-support", messages: 4,
                   updated_at: "2026-08-01T00:00:00Z")
    sessions.create(id: id, vars: { "agent" => agent, "customer" => "c-1" })
    messages.times { |i| sessions.append_messages(id, { "role" => "user", "content" => "msg #{i}" }) }
    record = sessions.find(id).to_h.merge("updated_at" => updated_at)
    backend.set("sessions", "session:#{id}", record)
    sessions.find(id)
  end

  describe "#run_once" do
    it "returns { claimed: false } when another worker holds the window" do
      backend.set("harvest_engine", "claim", { "claimed_at" => Time.now.utc.iso8601 })
      expect(engine.run_once).to eq(claimed: false)
      expect(calls).to be_empty
    end

    it "mines the oldest DUE session — idle, unmined, agent-tagged, harvest-enabled, with a grounding matcher" do
      due = seed_session(id: "acme:due")
      seed_session(id: "acme:fresh", updated_at: Time.now.utc.iso8601) # not idle
      seed_session(id: "acme:short", messages: 2)                     # too short
      seed_session(id: "acme:untagged", agent: nil)                   # no agent
      already = seed_session(id: "acme:already")
      harvest_store.mark_mined("acme:already")

      summary = engine.run_once

      expect(summary[:claimed]).to be(true)
      expect(calls.map { |p| p[:session_ids] }).to eq([["acme:due"]])
      expect(summary[:mined]).to eq(1)
      expect(summary[:skipped]).to eq(0)
      expect(summary[:errors]).to eq(0)
    end

    it "the loop-stop switch: an agent with harvest.enabled: false is NEVER mined — with nothing enabled the loop is inert (no claim)" do
      seed_session(id: "acme:off")
      off = { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m",
        harvest: { "enabled" => false },
        grounding: { "matcher" => { "sku" => '\bSKU\d{4}\b' } }
      ) }
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: idle_hours, profiles: off)
      expect(e.run_once).to eq(claimed: false)
      expect(calls).to be_empty
    end

    it "an agent without a grounding matcher is not scanned (the D3 pre-filter)" do
      seed_session(id: "acme:no_grounding")
      no_matcher = { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m", harvest: { "enabled" => true }
      ) }
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: idle_hours, profiles: no_matcher)
      expect(e.run_once[:mined]).to eq(0)
      expect(calls).to be_empty
    end

    it "one session per pass (each is a model call); the window paces the rest" do
      seed_session(id: "acme:older", updated_at: "2026-08-01T00:00:00Z")
      seed_session(id: "acme:newer", updated_at: "2026-08-02T00:00:00Z")
      summary = engine.run_once
      expect(calls.map { |p| p[:session_ids] }).to eq([["acme:older"]])
      expect(summary[:mined]).to eq(1)
    end

    it "counts skips returned by the runner" do
      seed_session(id: "acme:s")
      calls_holder = []
      skipping = Class.new do
        def initialize(calls) = (@calls = calls)
        def call(command)
          @calls << command.payload
          { mined: false, skipped: "no_model" }
        end
      end.new(calls_holder)
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: skipping,
                              window: 300, idle_hours: idle_hours, profiles: profiles)
      summary = e.run_once
      expect(summary[:skipped]).to eq(1)
      expect(summary[:mined]).to eq(0)
    end

    it "a raising runner is counted in errors and the pass continues" do
      seed_session(id: "acme:bad")
      raising = Class.new do
        def call(_command) = raise("provider exploded")
      end.new
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: raising,
                              window: 300, idle_hours: idle_hours, profiles: profiles)
      summary = e.run_once
      expect(summary[:errors]).to eq(1)
      expect(summary[:mined]).to eq(0)
    end

    it "is inert without a declaring profile — no claim, no scan, no runner calls" do
      seed_session(id: "acme:s", messages: 8)
      inert = described_class.new(store: backend, harvest_store: harvest_store,
                                  session_store: sessions, runner: runner,
                                  window: 300, idle_hours: idle_hours, profiles: {})
      expect(inert.run_once).to eq(claimed: false)
      expect(calls).to be_empty
      expect(backend.get("harvest_engine", "claim")).to be_nil
    end

    it "E1's engine half: the mined session record is byte-identical after the pass (the fork wrote nothing)" do
      seed_session(id: "acme:e1")
      before = sessions.find("acme:e1").to_h
      engine.run_once
      expect(sessions.find("acme:e1").to_h).to eq(before)
    end

    it "the scan honors the PROFILE's own bounds — an ineligible oldest session never starves the queue (the head-of-line fix)" do
      # the pack declares min_messages: 5; session a has 4 messages -> RunHarvest
      # would reject it and write no marker, so it must NOT be elected at all.
      profile_config = { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m",
        harvest: { "enabled" => true, "idle_hours" => 6, "min_messages" => 5 },
        grounding: { "matcher" => { "sku" => '\bSKU\d{4}\b' } }
      ) }
      seed_session(id: "acme:old_short", messages: 4, updated_at: "2026-08-01T00:00:00Z")
      seed_session(id: "acme:older_mineable", messages: 6, updated_at: "2026-08-02T00:00:00Z")
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: 24, profiles: profile_config)

      5.times { e.run_once }
      # the mineable session is reached — the too-short one never holds the head
      expect(calls.map { |p| p[:session_ids] }).to eq([["acme:older_mineable"]])
    end
  end

  describe "#start" do
    it "returns false when idle_hours <= 0 — the engine default OFF switch (parity)" do
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: 0, profiles: profiles)
      expect(e.start(parent: double)).to be(false)
    end

    it "returns false without a harvest declaration — the loop stays off" do
      e = described_class.new(store: backend, harvest_store: harvest_store,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: idle_hours, profiles: {})
      expect(e.start(parent: double)).to be(false)
    end
  end
end