# frozen_string_literal: true

require "spec_helper"

# RFC-0032 C4 — the tick-driven fold of WS7 outcomes into pack-declared stages.
# E1 lives here: the incremental fold, the recompute repair path, idempotence
# across crashes, the claim window and the skip rules.
RSpec.describe Insika::FunnelFold do
  let(:backend) { Insika::Stores::Memory.new }
  let(:outcome_store) { Insika::OutcomeStore.new(store: backend) }
  let(:funnel_store) { Insika::FunnelStore.new(store: backend) }
  let(:declaration) do
    { "stages" => %w[greeted qualified cart paid],
      "advance_on" => { "qualified" => "qualified", "abandoned_cart" => "cart",
                        "pix_paid" => "paid" },
      "primary" => "paid", "attribution_window" => "72h" }
  end
  let(:profiles) do
    Insika::StaticProfileSource.new(
      "store-support" => Insika::AgentProfile.build(id: "store-support", model: "m",
                                                     funnel: declaration),
      "no-funnel" => Insika::AgentProfile.build(id: "no-funnel", model: "m")
    )
  end

  def fold(now: Time.iso8601("2026-08-14T12:00:00Z"), window: 300, store: backend,
           outcome: outcome_store, funnel: funnel_store, source: profiles)
    described_class.new(outcome_store: outcome, funnel_store: funnel,
                        profiles: source, store: store, window: window, now: now)
  end

  def emit(agent: "store-support", tenant: nil, outcome: "qualified", at: nil, id: SecureRandom.uuid)
    outcome_store.create(tenant: tenant, agent: agent, outcome: outcome,
                         at: at || Time.iso8601("2026-08-14T10:00:00Z"), id: id)
  end

  describe "#run — the faithful fold (E1)" do
    it "folds new outcomes into cumulative counts on the declared order, primary included" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      emit(agent: "store-support", outcome: "pix_paid", at: Time.iso8601("2026-08-14T11:00:00Z"))
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-15T09:00:00Z"))

      summary = fold.run
      expect(summary[:claimed]).to be(true)
      expect(summary[:folded]).to eq(3)
      expect(summary[:pairs]).to eq(1)
      expect(summary[:skipped]).to eq(0)

      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 2, "qualified" => 2, "cart" => 1, "paid" => 1)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-15"))
        .to eq("greeted" => 1, "qualified" => 1)
    end

    it "an unmapped outcome kind is skipped and counted" do
      emit(agent: "store-support", outcome: "escalation", at: Time.iso8601("2026-08-14T10:00:00Z"))

      summary = fold.run
      expect(summary[:folded]).to eq(0)
      expect(summary[:skipped]).to eq(1)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq({})
    end

    it "pairs without a funnel are untouched" do
      emit(agent: "no-funnel", outcome: "qualified")
      summary = fold.run
      expect(summary[:pairs]).to eq(0)
      expect(summary[:folded]).to eq(0)
      expect(funnel_store.day(tenant: "platform", agent: "no-funnel", day: "2026-08-14")).to eq({})
    end

    it "a malformed declaration is skipped without raising" do
      broken_profiles = Insika::StaticProfileSource.new(
        "broken" => Insika::AgentProfile.build(
          id: "broken", model: "m",
          funnel: { "stages" => [], "advance_on" => {}, "primary" => "x" }
        )
      )
      emit(agent: "broken", outcome: "qualified")

      f = fold(source: broken_profiles)
      summary = f.run
      expect(summary[:claimed]).to be(true)
      expect(summary[:pairs]).to eq(0)
      expect(summary[:folded]).to eq(0)
    end

    it "two tenants fold into disjoint cells" do
      emit(agent: "store-support", tenant: "acme", outcome: "qualified")
      emit(agent: "store-support", tenant: "zed", outcome: "pix_paid")

      fold.run
      expect(funnel_store.day(tenant: "acme", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 1, "qualified" => 1)
      expect(funnel_store.day(tenant: "zed", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 1, "qualified" => 1, "cart" => 1, "paid" => 1)
    end
  end

  describe "#run — idempotence and the cursor (D3)" do
    let(:now) { Time.iso8601("2026-08-14T12:00:00Z") }

    it "a second pass with no new outcomes folds nothing" do
      emit(agent: "store-support", outcome: "qualified")
      f = fold(now: now)
      expect(f.run[:folded]).to eq(1)
      second = fold(now: now + 301).run
      expect(second[:folded]).to eq(0)
      expect(second[:pairs]).to eq(1)
    end

    it "records at the cursor's boundary second are not double counted (crash replay)" do
      at = Time.iso8601("2026-08-14T10:00:00Z")
      emit(agent: "store-support", outcome: "qualified", at: at, id: "a")
      emit(agent: "store-support", outcome: "pix_paid", at: at, id: "b")

      f = fold(now: now)
      f.run
      # crash replay: the same two records (same ids) are re-fed
      replay = fold(now: now + 301)
      summary = replay.run
      expect(summary[:folded]).to eq(0)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 2, "qualified" => 2, "cart" => 1, "paid" => 1)
    end

    it "a pass picks up only the records newer than the cursor" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      f = fold(now: now)
      f.run

      emit(agent: "store-support", outcome: "pix_paid", at: Time.iso8601("2026-08-14T11:00:00Z"))
      summary = fold(now: now + 301).run
      expect(summary[:folded]).to eq(1)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 2, "qualified" => 2, "cart" => 1, "paid" => 1)
    end

    it "the cursor stores the newest folded timestamp + its ids" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      fold(now: now).run
      cursor = funnel_store.cursor(tenant: "platform", agent: "store-support")
      expect(cursor["at"]).to eq("2026-08-14T10:00:00Z")
      expect(cursor["ids"].size).to eq(1)
    end
  end

  describe "#run — the claim window (D3)" do
    it "a second run inside the window returns {claimed: false}" do
      now = Time.iso8601("2026-08-14T12:00:00Z")
      f = fold(now: now)
      expect(f.run[:claimed]).to be(true)
      expect(f.run[:claimed]).to be(false)
    end

    it "a run after the window claims again" do
      now = Time.iso8601("2026-08-14T12:00:00Z")
      f = fold(now: now)
      f.run
      later = fold(now: now + 301)
      summary = later.run
      expect(summary[:claimed]).to be(true)
      expect(summary[:folded]).to eq(0)
    end
  end

  describe "#run — pair failure isolation" do
    it "a raising pair leaves the other pairs folded" do
      emit(agent: "store-support", outcome: "qualified")
      emit(agent: "other", outcome: "qualified")

      # the "other" half's profile lookup raises (a broken store/backing) — its
      # pair must not hold the "store-support" pair's funnel hostage.
      real_source = profiles
      flaky = Struct.new(:real) do
        def all = []
        def ids = []
        def fetch(agent) = (raise("boom") if agent == "other") || real.fetch(agent)
      end.new(real_source)
      f = fold(source: flaky)
      summary = f.run
      expect(summary[:folded]).to eq(1)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 1, "qualified" => 1)
      expect(funnel_store.day(tenant: "platform", agent: "other", day: "2026-08-14")).to eq({})
    end
  end

  describe "#recompute (E1's repair path)" do
    let(:now) { Time.iso8601("2026-08-14T12:00:00Z") }

    it "recompute == incremental: identical day cells" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      emit(agent: "store-support", outcome: "pix_paid", at: Time.iso8601("2026-08-14T11:00:00Z"))
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-15T09:00:00Z"))
      f = fold
      f.run

      incremental = funnel_store.days(tenant: "platform", agent: "store-support")
      funnel_store.purge(tenant: "platform")

      decl = Insika::FunnelDeclaration.parse!(declaration)
      folded = f.recompute(tenant: "platform", agent: "store-support", declaration: decl)
      expect(folded).to eq(3)
      expect(funnel_store.days(tenant: "platform", agent: "store-support")).to eq(incremental)
    end

    it "rebuilds from every outcome record even when the cursor is behind (backfill repair)" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      f = fold(now: now)
      f.run
      # a BACKFILLED record with an `at` older than the cursor — invisible
      # incrementally, repaired by recompute:
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-13T10:00:00Z"))
      expect(fold(now: now + 301).run[:folded]).to eq(0)

      decl = Insika::FunnelDeclaration.parse!(declaration)
      f.recompute(tenant: "platform", agent: "store-support", declaration: decl)
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-13"))
        .to eq("greeted" => 1, "qualified" => 1)
    end

    it "wipes the pair's day cells first" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      funnel_store.add(tenant: "platform", agent: "store-support", at: Time.iso8601("2026-08-10T00:00:00Z"),
                       counts: { "greeted" => 99 })

      decl = Insika::FunnelDeclaration.parse!(declaration)
      f = fold
      expect(f.recompute(tenant: "platform", agent: "store-support", declaration: decl)).to eq(1)
      expect(funnel_store.days(tenant: "platform", agent: "store-support").keys)
        .to eq(%w[2026-08-14])
    end

    it "a single-tenant recompute never folds another tenant's records (blocker: nil filter)" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      emit(agent: "store-support", tenant: "acme", outcome: "pix_paid",
           at: Time.iso8601("2026-08-14T11:00:00Z"))
      funnel_store.add(tenant: "acme", agent: "store-support", at: Time.iso8601("2026-08-13T00:00:00Z"),
                       counts: { "greeted" => 50 })

      decl = Insika::FunnelDeclaration.parse!(declaration)
      f = fold
      # the no-tenant pair recomputes: ONLY its own record folds, acme's cell
      # (and record) stay untouched
      expect(f.recompute(tenant: "platform", agent: "store-support", declaration: decl)).to eq(1)
      expect(funnel_store.days(tenant: "platform", agent: "store-support"))
        .to eq("2026-08-14" => { "greeted" => 1, "qualified" => 1 })
      expect(funnel_store.day(tenant: "acme", agent: "store-support", day: "2026-08-13"))
        .to eq("greeted" => 50)
    end

    it "a single-tenant recompute REBUILDS the pair's cells (blocker: purge prefix)" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      # a stale cell from a previous, larger reality:
      funnel_store.add(tenant: nil, agent: "store-support", at: Time.iso8601("2026-08-10T00:00:00Z"),
                       counts: { "greeted" => 99 })

      decl = Insika::FunnelDeclaration.parse!(declaration)
      fold.recompute(tenant: nil, agent: "store-support", declaration: decl)
      # 1, not 100 — the pair was wiped before rebuilding, never summed on top
      expect(funnel_store.day(tenant: nil, agent: "store-support", day: "2026-08-10")).to eq({})
      expect(funnel_store.day(tenant: nil, agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 1, "qualified" => 1)
    end

    it "an emptied pair's recompute resets the cursor" do
      decl = Insika::FunnelDeclaration.parse!(declaration)
      f = fold
      f.recompute(tenant: "platform", agent: "store-support", declaration: decl)
      expect(funnel_store.cursor(tenant: "platform", agent: "store-support"))
        .to eq("at" => nil, "ids" => [])
    end
  end

  describe "#run — the skip/advance rule" do
    it "a pass with only unmapped kinds still advances the cursor (no re-read forever)" do
      emit(agent: "store-support", outcome: "escalation", at: Time.iso8601("2026-08-14T10:00:00Z"))

      now = Time.iso8601("2026-08-14T12:00:00Z")
      first = fold(now: now).run
      expect(first[:folded]).to eq(0)
      expect(first[:skipped]).to eq(1)

      second = fold(now: now + 301).run
      expect(second[:folded]).to eq(0)
      expect(second[:skipped]).to eq(0) # not re-counted every window

      cursor = funnel_store.cursor(tenant: "platform", agent: "store-support")
      expect(cursor["at"]).to eq("2026-08-14T10:00:00Z")
    end

    it "same-day events at different times fold into ONE day cell write (the counts are right)" do
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T10:00:00Z"))
      emit(agent: "store-support", outcome: "qualified", at: Time.iso8601("2026-08-14T11:00:00Z"))
      emit(agent: "store-support", outcome: "pix_paid", at: Time.iso8601("2026-08-14T12:00:00Z"))

      fold.run
      expect(funnel_store.day(tenant: "platform", agent: "store-support", day: "2026-08-14"))
        .to eq("greeted" => 3, "qualified" => 3, "cart" => 1, "paid" => 1)
    end
  end
end
