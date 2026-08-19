# frozen_string_literal: true

require "spec_helper"

# the schedule rows — declaration-derived, engine-owned runtime state.
RSpec.describe Insika::ScheduleStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }
  let(:now) { Time.iso8601("2026-08-19T14:00:00Z") }

  def declaration(**over)
    { "id" => "daily", "every" => 3600, "message" => "run the report",
      "tz" => "Etc/UTC" }.merge(over)
  end

  describe "#sync_declared" do
    it "creates a row with next_fire_at one interval out for `every`" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration], now: now)
      row = store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(row).not_to be_nil
      expect(row.enabled).to be(true)
      expect(row.next_fire_at).to eq((now + 3600).iso8601)
      expect(row.last_run_at).to be_nil
    end

    it "computes next_fire_at from the cron expression in the schedule's tz" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration("cron" => "0 22 * * *", "every" => nil)],
                          now: Time.iso8601("2026-08-19T21:30:00Z"))
      row = store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(Time.iso8601(row.next_fire_at)).to eq(Time.iso8601("2026-08-19T22:00:00Z"))

      # a non-UTC tz materializes in that zone: Sao_Paulo is UTC-3
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration("cron" => "0 22 * * *", "every" => nil,
                                                  "tz" => "America/Sao_Paulo")],
                          now: Time.iso8601("2026-08-19T21:30:00Z"))
      row = store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(Time.iso8601(row.next_fire_at)).to eq(Time.iso8601("2026-08-20T01:00:00Z"))
    end

    it "keeps runtime state across an unchanged re-sync" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration], now: now)
      store.transition_fire(id: "daily", tenant: "platform", agent: "reporter",
                            task_id: "t-1", next_fire_at: now + 7200, now: now)
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration], now: now + 3600)
      row = store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(row.last_run_at).to eq(now.iso8601)
      expect(row.last_task_id).to eq("t-1")
    end

    it "a changed declaration recomputes the lattice" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration(every: 3600)], now: now)
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration(every: 86_400)], now: now)
      row = store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(row.every).to eq(86_400)
      expect(row.next_fire_at).to eq((now + 86_400).iso8601)
    end

    it "a malformed or undeclared schedule is dropped (never fires with stale text)" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration], now: now)
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration("cron" => "broken")], now: now)
      expect(store.find(tenant: "platform", agent: "reporter", id: "daily")).to be_nil
    end

    it "undeclared rows are removed per agent" do
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [declaration], now: now)
      store.sync_declared(tenant: "platform", agent: "reporter",
                          schedules: [], now: now)
      expect(store.for_agent(tenant: "platform", agent: "reporter")).to be_empty
    end

    it "keys rows per agent (two agents, two rows)" do
      store.sync_declared(tenant: "platform", agent: "a", schedules: [declaration], now: now)
      store.sync_declared(tenant: "platform", agent: "b", schedules: [declaration], now: now)
      expect(store.all.size).to eq(2)
    end
  end

  describe "#due" do
    it "returns enabled + due rows, oldest first" do
      store.sync_declared(tenant: "platform", agent: "a",
                          schedules: [declaration("every" => 7200), declaration("id" => "sooner", "every" => 60)],
                          now: now)
      expect(store.due(now: now + 30).map(&:id)).to eq([])
      expect(store.due(now: now + 90).map(&:id)).to eq(%w[sooner]) # the 3600s one is not due (t+3690)
      expect(store.due(now: now + 3700).map(&:id)).to eq(%w[sooner])
    end

    it "a disabled row is never due" do
      store.sync_declared(tenant: "platform", agent: "a",
                          schedules: [declaration("enabled" => false, "every" => 30)], now: now)
      expect(store.due(now: now + 60)).to be_empty
    end

    it "a nil next_fire_at (a cron that can never fire) is never due" do
      store.sync_declared(tenant: "platform", agent: "a",
                          schedules: [declaration("cron" => "0 0 31 2 *", "every" => nil)], now: now)
      expect(store.due(now: now + 86_400)).to be_empty
    end
  end

  describe "the engine's claims" do
    it "transition_fire stamps the run and clears the skip" do
      store.sync_declared(tenant: "platform", agent: "a", schedules: [declaration(every: 60)], now: now)
      store.mark_skip(id: "daily", tenant: "platform", agent: "a", reason: :overlap,
                      next_fire_at: now + 7200, now: now)
      store.transition_fire(id: "daily", tenant: "platform", agent: "a", task_id: "t-9",
                            next_fire_at: now + 120, now: now)
      row = store.find(tenant: "platform", agent: "a", id: "daily")
      expect(row.last_run_at).to eq(now.iso8601)
      expect(row.last_task_id).to eq("t-9")
      expect(row.last_skip).to be_nil
      expect(row.next_fire_at).to eq((now + 120).iso8601)
    end

    it "mark_skip records the reason and advances the lattice" do
      store.sync_declared(tenant: "platform", agent: "a", schedules: [declaration(every: 60)], now: now)
      store.mark_skip(id: "daily", tenant: "platform", agent: "a", reason: :budget,
                      next_fire_at: now + 3660, now: now + 60)
      row = store.find(tenant: "platform", agent: "a", id: "daily")
      expect(row.last_skip).to eq("at" => (now + 60).iso8601, "reason" => "budget")
      expect(row.next_fire_at).to eq((now + 3660).iso8601)
    end
  end

  describe "the LGPD sweep" do
    it "purge(tenant:) removes that tenant's rows only" do
      store.sync_declared(tenant: "acme", agent: "a", schedules: [declaration], now: now)
      store.sync_declared(tenant: "platform", agent: "b", schedules: [declaration], now: now)
      expect(store.purge(tenant: "acme")).to eq(1)
      expect(store.all.map(&:agent)).to eq(%w[b])
    end
  end
end