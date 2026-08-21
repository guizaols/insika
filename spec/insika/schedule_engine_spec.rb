# frozen_string_literal: true

require "spec_helper"
require "async"
require "tmpdir"

# the tick's recurring firer — the experiments E1..E4:
# at-most-once, overlap skips, budget skips, the no-catch-up policy — plus
# the reconciliation (declarations -> rows) and the synthetic-turn shape.
RSpec.describe Insika::ScheduleEngine do
  let(:backend) { Insika::Stores::Memory.new }
  let(:schedule_store) { Insika::ScheduleStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:budget_ledger) { Insika::BudgetLedger.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:now) { Time.iso8601("2026-08-19T14:00:00Z") }

  DECLARATION = { "id" => "daily", "every" => 60, "message" => "Run the report now." }.freeze

  let(:profile) { Insika::AgentProfile.build(id: "reporter", model: "m", schedules: [DECLARATION]) }
  let(:profiles) { Insika::StaticProfileSource.new("reporter" => profile) }

  # a stub executor that records spawns (task + profile) and SIMULATES the
  # turn finishing (queued -> running -> completed), so the next pass never
  # mistakes the stub's unrun task for a live overlap.
  let(:executor) do
    spawns = []
    executor = double("executor")
    allow(executor).to receive(:spawn_in_session) do |task, profile:, **|
      task_store.transition(task.id, to: :running)
      task_store.transition(task.id, to: :completed)
      spawns << [task, profile]
    end
    executor.instance_variable_set(:@spawns, spawns)
    executor
  end
  let(:spawns) { executor.instance_variable_get(:@spawns) }

  # The row is seeded BEFORE the pass (the engine's own sync would otherwise
  # put the first fire a full period out): `every: 60` -> next_fire_at now+60,
  # due from now+61. The default pass runs at now+121 (the first window).
  def seeded(declarations = [DECLARATION])
    schedule_store.sync_declared(tenant: "platform", agent: "reporter",
                                 schedules: declarations, now: now)
  end

  def run_pass(declarations = [DECLARATION], now_at: now + 121)
    source = Insika::StaticProfileSource.new("reporter" => profile_with(declarations))
    run_pass_for(source, now_at: now_at)
  end

  def profile_with(declarations)
    Insika::AgentProfile.build(id: "reporter", model: "m", schedules: declarations)
  end

  def run_pass_for(source, now_at:, over: {}, store: backend)
    described_class.new(
      store: store, schedule_store: schedule_store, task_store: task_store,
      session_store: session_store, profiles: source, executor: executor,
      budget_ledger: budget_ledger, event_stream: event_stream,
      window: 300, now: now_at, **over
    ).run
  end

  # the rows for a cross-handle run live on the given backend directly.
  def seeded_schedule(handle)
    Insika::ScheduleStore.new(store: handle)
                          .sync_declared(tenant: "platform", agent: "reporter",
                                         schedules: [DECLARATION], now: now)
  end

  describe "the pass" do
    it "claims its window and reports a due schedule as fired" do
      seeded
      summary = run_pass
      expect(summary[:claimed]).to be(true)
      expect(summary[:fired]).to eq(1)
      expect(summary[:skipped]).to eq(0)
      expect(summary[:errors]).to eq(0)
    end

    it "a second worker within the window gets {claimed: false}" do
      seeded
      run_pass
      expect(run_pass[:claimed]).to be(false)
    end

    it "emits :schedule_fired with ids only" do
      seeded
      run_pass
      event = event_stream.events.find { |e| e.type == :schedule_fired }
      expect(event).not_to be_nil
      expect(event.data).to eq(id: "daily", agent: "reporter",
                               task_id: event.data[:task_id])
    end

    it "a bare install (no schedules declared anywhere) is inert" do
      empty = Insika::StaticProfileSource.new("reporter" =>
                                              Insika::AgentProfile.build(id: "reporter", model: "m"))
      summary = run_pass_for(empty, now_at: now + 121)
      expect(summary[:fired]).to eq(0)
      expect(spawns).to be_empty
    end
  end

  describe "E1 — at-most-once" do
    it "`every: 60` fires exactly one turn per window, across consecutive passes" do
      seeded
      run_pass # at now+121 (lattice now+60) fires once
      summary = run_pass(now_at: now + 421) # the next claim window
      expect(summary[:fired]).to eq(1)
      expect(spawns.size).to eq(2)
    end

    it "two workers racing the same window fire exactly once" do
      seeded
      summary = run_pass
      expect(summary[:fired]).to eq(1)
      expect(run_pass[:claimed]).to be(false)
      expect(spawns.size).to eq(1)
    end

    it "two SQLite handles racing the same window fire exactly one task (cross-process claim)" do
      Dir.mktmpdir do |dir|
        db_path = File.join(dir, "schedules.db")
        handle_a = Insika::Stores::SQLite.new(path: db_path)
        handle_b = Insika::Stores::SQLite.new(path: db_path)
        seeded_schedule(handle_a)
        profiles_a = profiles
        # a spawn recorder that does NOT touch the memory task_store (the
        # thread's turns live on the SQLite handle — the shared stub would
        # transition a task it cannot find).
        executor_a = Object.new
        executor_a.define_singleton_method(:spawn_in_session) do |task, profile:, **|
          task
        end
        barrier = Queue.new
        results = [handle_a, handle_b].map do |handle|
          Thread.new do
            barrier.pop
            described_class.new(
              store: handle,
              schedule_store: Insika::ScheduleStore.new(store: handle),
              task_store: Insika::TaskStore.new(store: handle),
              session_store: Insika::SessionStore.new(store: handle),
              profiles: profiles_a, executor: executor_a,
              budget_ledger: Insika::BudgetLedger.new(store: handle),
              window: 300, now: now + 121
            ).run
          end
        end
        2.times { barrier << :go }
        fired = results.map(&:value).count { |s| s[:fired] == 1 }

        expect(fired).to eq(1), "both handles fired the same window: #{fired}"
      ensure
        handle_a&.close
        handle_b&.close
      end
    end
  end

  describe "the synthetic turn" do
    it "creates a scheduled_run task with origin 'scheduled' and the schedule's message" do
      seeded
      run_pass
      task = spawns.first.first
      expect(task.command["type"]).to eq("scheduled_run")
      expect(task.command["payload"]["agent"]).to eq("reporter")
      expect(task.command["payload"]["message"]).to eq("Run the report now.")
      expect(task.command["payload"]["origin"]).to eq("scheduled")
      expect(task.command["meta"]["tenant"]).to eq("platform")
    end

    it "session_mode new creates a fresh session per run" do
      seeded
      run_pass
      session_id = spawns.first.first.command["session_id"]
      expect(session_id).not_to be_nil
      expect(session_store.find(session_id)).not_to be_nil
    end

    it "session_mode fixed reuses ONE standing session across runs" do
      standing = { "id" => "standing", "every" => 60, "message" => "report",
                   "session_mode" => "fixed", "session_id" => "standing-runs" }
      seeded([standing])
      run_pass([standing])
      run_pass([standing], now_at: now + 421)
      session_ids = spawns.map { |(task, _)| task.command["session_id"] }.uniq
      expect(session_ids).to eq(["standing-runs"])
    end

    it "the schedule's overrides ride the spawned profile, never the base" do
      declaration = { "id" => "daily", "every" => 60, "message" => "x",
                      "overrides" => { "turn_timeout" => 900, "max_tool_calls" => 200 } }
      seeded([declaration])
      run_pass([declaration])
      _task, profile = spawns.first
      expect(profile.limits[:turn_timeout]).to eq(900)
      expect(profile.limits[:max_tool_calls]).to eq(200)
      # untouched keys keep the base values (parity for a sibling schedule)
      expect(profile.limits[:tool_timeout]).to eq(60)
      expect(profile.id).to eq("reporter")
    end

    it "the run is a durable task even when spawn fails (queued, recovered by the tick)" do
      seeded
      allow(executor).to receive(:spawn_in_session).and_raise(Insika::StoreError, "boom")
      run_pass
      row = schedule_store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(row.last_task_id).not_to be_nil
      expect(task_store.find(row.last_task_id).status).to eq(:queued)
    end
  end

  describe "E2 — overlap skips" do
    # the row whose last task is STILL LIVE at the pass time (the stub
    # completes turns, so the live task is seeded by hand, not by a fire).
    def seeded_running(declaration: DECLARATION, status: :running)
      seeded([declaration])
      task = task_store.create(command: { "type" => "scheduled_run",
                                          "payload" => { "agent" => "reporter" } },
                               session_id: nil)
      task_store.transition(task.id, to: status)
      schedule_store.transition_fire(id: "daily", tenant: "platform", agent: "reporter",
                                     task_id: task.id, next_fire_at: now + 60, now: now)
      task
    end

    it "a still-live last task makes the next window a recorded skip; the one after fires" do
      running = seeded_running
      summary = run_pass # at now+121: next=now+60 due, but the run is LIVE
      expect(summary[:fired]).to eq(0)
      expect(summary[:skip_reasons]).to eq("overlap" => 1)
      row = schedule_store.find(tenant: "platform", agent: "reporter", id: "daily")
      expect(row.last_skip).to eq("at" => (now + 121).iso8601, "reason" => "overlap")

      # the task finishes -> the following window fires normally
      task_store.transition(running.id, to: :failed)
      summary = run_pass(now_at: now + 421)
      expect(summary[:fired]).to eq(1)
    end

    it "a terminal previous run is never an overlap" do
      seeded_running(status: :failed)
      expect(run_pass[:fired]).to eq(1)
    end
  end

  describe "E3 — budget skips" do
    def budget_profile(schedules, budget)
      Insika::AgentProfile.build(id: "reporter", model: "m", schedules: schedules,
                                 budget: budget)
    end

    it "a hard budget at/over its cap skips, recorded, never queued" do
      declaration = { "id" => "daily", "every" => 30, "message" => "x" }
      seeded([declaration])
      budget_ledger.add(tenant: "platform", agent: "reporter", by: 9000, now: now)
      source = Insika::StaticProfileSource.new(
        "reporter" => budget_profile([declaration], { "daily" => 5000 })
      )
      summary = run_pass_for(source, now_at: now + 121)
      expect(summary[:fired]).to eq(0)
      expect(summary[:skip_reasons]).to eq("budget" => 1)
      expect(spawns).to be_empty # never queued
      expect(schedule_store.find(tenant: "platform", agent: "reporter", id: "daily")
             .last_skip["reason"]).to eq("budget")
    end

    it "a soft budget crosses and runs" do
      declaration = { "id" => "daily", "every" => 30, "message" => "x" }
      seeded([declaration])
      budget_ledger.add(tenant: "platform", agent: "reporter", by: 9000, now: now)
      source = Insika::StaticProfileSource.new(
        "reporter" => budget_profile([declaration], { "daily" => 5000, "soft" => true })
      )
      summary = run_pass_for(source, now_at: now + 121)
      expect(summary[:fired]).to eq(1)
    end
  end

  describe "E4 — the no-catch-up policy" do
    it "a window older than one claim window is a recorded :late skip, never replayed" do
      seeded
      run_pass # fires; next = now+120
      # the engine was 'down' long past the window: nothing replayed
      summary = run_pass(now_at: now + 6000)
      expect(summary[:fired]).to eq(0)
      expect(summary[:skip_reasons]).to eq("late" => 1)
      expect(schedule_store.find(tenant: "platform", agent: "reporter", id: "daily")
             .last_skip["reason"]).to eq("late")
      # the NEXT window fires — the lattice advanced, nothing queued
      summary = run_pass(now_at: now + 6300)
      expect(summary[:fired]).to eq(1)
    end

    it "a fire a few seconds late is on time, not a skip" do
      seeded
      # lattice now+60; firing at now+180 is only 120s stale — inside the window
      summary = run_pass(now_at: now + 180)
      expect(summary[:fired]).to eq(1)
    end
  end

  describe "the reconciliation is a data path, not magic" do
    it "undeclaring a schedule removes the row (and stops firing)" do
      seeded
      run_pass
      expect(schedule_store.all.size).to eq(1)
      run_pass([], now_at: now + 421)
      expect(schedule_store.all).to be_empty
    end
  end

  # C3.2's own finding: a scheduled turn has no caller to declare a tenant, so
  # the ScheduleEngine used to hardcode "platform" for EVERY agent — the
  # SAME tenant a schedule's own fired command carries (`current.tenant`,
  # threaded into budget ledger lookups and the command's own meta), which
  # means two qa-<store> agents scheduled in the same deployment would share
  # one tenant cell, defeating exactly the per-tenant isolation the calling
  # code (e.g. run_persona_eval) relies on.
  describe "ScheduleEngine.tenant_for (per-agent tenant, not a fixed constant)" do
    it "reads the agent's own metadata['tenant'], never the fixed default" do
      declared = Insika::AgentProfile.build(id: "qa-ocean-drop", model: "m",
                                            metadata: { "tenant" => "ocean-drop" },
                                            schedules: [DECLARATION])
      expect(described_class.tenant_for(declared)).to eq("ocean-drop")
    end

    it "falls back to the single-tenant default when nothing is declared (parity)" do
      expect(described_class.tenant_for(profile)).to eq("platform")
    end

    it "the fired command and the row both land under the DECLARED tenant" do
      declared = Insika::AgentProfile.build(id: "qa-ocean-drop", model: "m",
                                            metadata: { "tenant" => "ocean-drop" },
                                            schedules: [DECLARATION])
      source = Insika::StaticProfileSource.new("qa-ocean-drop" => declared)
      run_pass_for(source, now_at: now)       # reconciles: creates the row under "ocean-drop"
      run_pass_for(source, now_at: now + 300) # a later claim window: now due -> fires

      row = schedule_store.find(tenant: "ocean-drop", agent: "qa-ocean-drop", id: "daily")
      expect(row).not_to be_nil
      expect(schedule_store.find(tenant: "platform", agent: "qa-ocean-drop", id: "daily")).to be_nil

      task, = spawns.last
      expect(task.command["meta"]["tenant"]).to eq("ocean-drop")
    end
  end

  describe "isolation" do
    it "a failing schedule's transaction aborts ITS row, the loop continues" do
      seeded
      allow(task_store).to receive(:create).and_raise(Insika::StoreError, "boom")
      summary = run_pass
      expect(summary[:errors]).to eq(1)
      expect(summary[:fired]).to eq(0)
      expect(schedule_store.find(tenant: "platform", agent: "reporter", id: "daily")).not_to be_nil
    end
  end
end