# frozen_string_literal: true

require "spec_helper"

# the trigger — finds due (idle, customer-tagged, undistilled)
# sessions and distills them on a worker fiber, off the tick's critical path
# and off every customer turn's path (D8). The scan uses the engine default
# idle_hours as the lower bound; the per-agent value is re-checked inside
# RunDistillation.
RSpec.describe Insika::DistillEngine do
  subject(:engine) do
    described_class.new(store: backend, proposal_store: proposals,
                        session_store: sessions, runner: runner,
                        window: 300, idle_hours: idle_hours, profiles: profiles)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:proposals) { Insika::ProposalStore.new(store: backend) }
  let(:idle_hours) { 6 }
  let(:profiles) do
    { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m",
        distill: { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 }
      ) }
  end

  let(:calls) { [] }
  let(:runner) do
    Class.new do
      def initialize(calls) = (@calls = calls)
      def call(command)
        @calls << command.payload
        { distilled: true }
      end
    end.new(calls)
  end

  def seed_session(id: "acme:sess_1", customer: "c-1", agent: "store-support",
                   messages: 4, updated_at: "2026-08-10T00:00:00Z")
    sessions.create(id: id)
    sessions.update_vars(id, "customer" => customer, "agent" => agent)
    messages.times do |i|
      sessions.append_messages(id, { "role" => "user", "content" => "message #{i}" })
    end
    record = sessions.find(id).to_h.merge("updated_at" => updated_at)
    backend.set("sessions", "session:#{id}", record)
    sessions.find(id)
  end

  describe "#run_once" do
    it "returns { claimed: false } when another worker holds the window" do
      backend.set("distill", "claim", { "claimed_at" => Time.now.utc.iso8601 })
      expect(engine.run_once).to eq(claimed: false)
    end

    it "picks only idle, customer-tagged, undistilled sessions with enough messages" do
      due = seed_session(id: "acme:due")
      seed_session(id: "acme:fresh", updated_at: Time.now.utc.iso8601)      # not idle
      seed_session(id: "acme:short", messages: 2)                          # too short
      seed_session(id: "acme:untagged", customer: nil)                     # no customer
      seed_session(id: "acme:no_agent", agent: nil)                        # no agent
      already = seed_session(id: "acme:already")
      proposals.mark_distilled(already.id, agent: "store-support", proposals: 0, dropped: {})

      summary = engine.run_once

      expect(summary[:claimed]).to be(true)
      expect(calls.map { |p| p[:session_id] }).to eq(["acme:due"])
      expect(summary[:distilled]).to eq(1)
      expect(summary[:skipped]).to eq(0)
      expect(summary[:errors]).to eq(0)
    end

    it "oldest due session distills first" do
      seed_session(id: "acme:newer", updated_at: "2026-08-15T00:00:00Z")
      seed_session(id: "acme:older", updated_at: "2026-08-01T00:00:00Z")
      engine.run_once
      expect(calls.map { |p| p[:session_id] }).to eq(["acme:older", "acme:newer"])
    end

    it "counts skips returned by the runner" do
      seed_session(id: "acme:s")
      calls_holder = []
      skipping = Class.new do
        def initialize(calls) = (@calls = calls)
        def call(command)
          @calls << command.payload
          { distilled: false, skipped: "too_fresh" }
        end
      end.new(calls_holder)
      e = described_class.new(store: backend, proposal_store: proposals,
                              session_store: sessions, runner: skipping, window: 300,
                              idle_hours: idle_hours, profiles: profiles)
      summary = e.run_once
      expect(summary[:skipped]).to eq(1)
      expect(summary[:distilled]).to eq(0)
    end

    it "a raising runner is counted in errors and the pass continues" do
      seed_session(id: "acme:bad")
      seed_session(id: "acme:good")
      raising = Class.new do
        def call(command)
          raise "boom" if command.payload[:session_id] == "acme:bad"

          { distilled: true }
        end
      end.new
      e = described_class.new(store: backend, proposal_store: proposals,
                              session_store: sessions, runner: raising, window: 300,
                              idle_hours: idle_hours, profiles: profiles)
      summary = e.run_once
      expect(summary[:errors]).to eq(1)
      expect(summary[:distilled]).to eq(1)
    end

    # Blocker 2 — without a distill declaration the engine is INERT: no claim,
    # no scan, no session-record reads. A pass would otherwise re-read every
    # session record every window forever (each due session skips at the
    # command, writes no marker, and repeats).
    it "is inert without a declaring profile — no claim, no scan, no runner calls" do
      seed_session(id: "acme:s", messages: 8)
      inert = described_class.new(store: backend, proposal_store: proposals,
                                  session_store: sessions, runner: runner,
                                  window: 300, idle_hours: idle_hours, profiles: {})
      expect(inert.run_once).to eq(claimed: false)
      expect(calls).to be_empty
      expect(backend.get("distill", "claim")).to be_nil
    end

    it "a declaring profile with enabled: false is not a declaration" do
      seed_session(id: "acme:s", messages: 8)
      off = { "store-support" => Insika::AgentProfile.build(
        id: "store-support", model: "m", distill: { "enabled" => false }
      ) }
      inert = described_class.new(store: backend, proposal_store: proposals,
                                  session_store: sessions, runner: runner,
                                  window: 300, idle_hours: idle_hours, profiles: off)
      expect(inert.run_once).to eq(claimed: false)
      expect(calls).to be_empty
    end
  end

  describe "#start" do
    it "returns false when idle_hours <= 0 — the engine default OFF switch (parity)" do
      e = described_class.new(store: backend, proposal_store: proposals,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: 0, profiles: profiles)
      expect(e.start(parent: double)).to be(false)
    end

    it "returns false without a distill declaration — the engine stays off (Blocker 2)" do
      e = described_class.new(store: backend, proposal_store: proposals,
                              session_store: sessions, runner: runner,
                              window: 300, idle_hours: 6, profiles: {})
      expect(e.start(parent: double)).to be(false)
    end
  end

  describe "E2 — the latch holds at engine level" do
    # a REAL RunDistillation as the runner: the engine triggers, the command
    # dedups against the ledger.
    let(:memory) { Insika::MemoryStore.new(store: backend) }
    let(:settings) { Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: backend)) }
    let(:events) { [] }
    let(:stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }
    let(:profile) do
      Insika::AgentProfile.build(id: "store-support", model: "m",
                                 distill: { "enabled" => true, "idle_hours" => 6, "min_messages" => 3 })
    end
    let(:distiller_factory) do
      Class.new do
        def initialize(d) = (@d = d)
        def call(_c) = @d
      end.new(distiller)
    end
    let(:distiller) do
      Class.new do
        def initialize(proposals) = (@proposals = proposals)
        def distill(**)
          { proposals: @proposals, dropped: { "schema" => 0, "unknown_key" => 0,
                                              "oversized" => 0, "bad_turns" => 0, "duplicate" => 0, "capped" => 0 },
            cost: nil }
        end
      end.new([{ "name" => "size", "value" => "M" }])
    end

    it "a dismissed tuple from session A never reappears when session B is distilled" do
      runner = Insika::Commands::RunDistillation.new(
        profiles: { "store-support" => profile }, proposal_store: proposals,
        session_store: sessions, memory_store: memory, settings_store: settings,
        event_stream: stream, distiller_factory: distiller_factory
      )
      engine = described_class.new(store: backend, proposal_store: proposals,
                                   session_store: sessions, runner: runner,
                                   window: 300, idle_hours: 6, profiles: profiles)

      seed_session(id: "acme:session_a")
      engine.run_once
      proposals.dismiss(id: proposals.pending(limit: 100).first.id)

      # a second pass within the window is claimed false; re-seed the claim for B
      seed_session(id: "acme:session_b")
      backend.set("distill", "claim", { "claimed_at" => Time.parse("2026-08-01T00:00:00Z").iso8601 })
      engine.run_once

      expect(proposals.pending(limit: 100)).to be_empty
      expect(proposals.decided?(tenant: "acme", customer: "c-1", key: "size", value: "M")).to be(true)
      expect(proposals.distilled?("acme:session_b")).to be(true)
    end
  end
end
