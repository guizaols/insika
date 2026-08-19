# frozen_string_literal: true

require "spec_helper"
require "async"

#   — the tick-driven firer. The experiments E1/E2/E3 live here:
# book-fire-deliver, the policy blocks, and silence ≠ refusal.
RSpec.describe Insika::FollowupEngine do
  let(:backend) { Insika::Stores::Memory.new }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:now) { Time.iso8601("2026-08-14T12:00:00Z") }

  let(:profile) do
    Insika::AgentProfile.build(
      id: "store-support", model: "m",
      followup: { "arm" => "schedule",
                  "policy" => { "quiet_hours" => nil,
                                "max_frequency" => "2/24h",
                                "cancel_keywords" => [],
                                "silence_after_sends" => 3 } }
    )
  end
  let(:profiles) { Insika::StaticProfileSource.new("store-support" => profile) }

  # a stub executor that records spawns instead of running turns
  let(:executor) do
    spawns = []
    executor = double("executor")
    allow(executor).to receive(:spawn_in_session) { |task, **| spawns << task }
    executor.instance_variable_set(:@spawns, spawns)
    executor
  end

  def engine(**over)
    described_class.new(
      store: backend, followup_store: followup_store, contact_store: contact_store,
      task_store: task_store, profiles: profiles, executor: executor,
      window: 300, now: now + 7200, event_stream: event_stream, **over
    )
  end

  def book!(at: nil, customer: "c-1", reason: "pix pending", session_id: "s-1",
            transport: "channel:whatsapp", id: SecureRandom.uuid, **rest)
    followup_store.create(tenant: "acme", agent: "store-support", customer: customer,
                          session_id: session_id, at: at || now + 3600, reason: reason,
                          arm: "schedule", transport: transport, id: id, now: now, **rest)
  end

  def granted(customer = "c-1")
    contact_store.set_granted(tenant: "acme", customer: customer, now: now)
  end

  def fired_tasks
    executor.instance_variable_get(:@spawns)
  end

  # seeds a follow-up RECORD directly through the backend — the path the cron
  # arm (or legacy data) uses, bypassing the tool's create-time dedup (D7).
  def seed_pending_pair(id:, at:, reason:)
    backend.set("followups",
                "acme:store-support:c-1:#{at.utc.iso8601}:#{id}",
                { "id" => id, "tenant" => "acme", "agent" => "store-support",
                  "customer" => "c-1", "session_id" => "s-1", "at" => at.utc.iso8601,
                  "reason" => reason, "arm" => "cron", "status" => "pending",
                  "task_id" => nil, "blocked_reason" => nil, "transport" => "channel:whatsapp",
                  "created_at" => now.iso8601, "updated_at" => now.iso8601 })
  end

  describe "E1 — book, fire, deliver" do
    it "a due record fires once: fired status, one task, SendMessage-shaped command" do
      book!(id: "e1")
      granted

      summary = engine.run
      expect(summary[:claimed]).to be(true)
      expect(summary[:fired]).to eq(1)
      expect(summary[:blocked]).to eq(0)
      expect(summary[:errors]).to eq(0)

      record = followup_store.find("e1")
      expect(record.status).to eq("fired")
      expect(record.task_id).not_to be_nil

      task = task_store.find(record.task_id)
      expect(task.command["type"]).to eq("scheduled_followup")
      expect(task.command["payload"]["origin"]).to eq("scheduled")
      expect(task.command["payload"]["agent"]).to eq("store-support")
      expect(task.command["payload"]["customer"]).to eq("c-1")
      expect(task.command["payload"]["message"]).to include("pix pending")
      expect(task.command["meta"]["tenant"]).to eq("acme")
      expect(task.command["meta"]["transport"]).to eq("channel:whatsapp")

      # the engine spawns the turn through the same pipeline as a customer message
      expect(fired_tasks.map(&:id)).to eq([record.task_id])
    end

    it "the turn is a first-class inbound turn (executor.spawn_in_session)" do
      book!
      granted
      engine.run
      expect(executor).to have_received(:spawn_in_session).once
    end

    it "two workers racing the same backend fire exactly once" do
      book!(id: "race")
      granted
      # second engine shares the stores but claims the window first
      engine.run
      summary = engine.run
      expect(summary[:claimed]).to be(false)
      record = followup_store.find("race")
      expect(record.status).to eq("fired")
      expect(fired_tasks.size).to eq(1)
    end

    it "emits :followup_fired with ids, never the reason text" do
      book!(id: "ev")
      granted
      engine.run
      event = event_stream.events.find { |e| e.type == :followup_fired }
      expect(event).not_to be_nil
      expect(event.data).to eq(id: "ev", agent: "store-support", customer: "c-1",
                               task_id: event.data[:task_id], arm: "schedule")
      expect(event.data[:reason]).to be_nil
    end
  end

  describe "E2 — the policy blocks" do
    it "a never-messaged customer blocks with :consent (no cell)" do
      book!(id: "consent")
      summary = engine.run
      expect(summary[:fired]).to eq(0)
      expect(summary[:blocked]).to eq(1)
      expect(summary[:blocked_reasons]).to eq("consent" => 1)
      record = followup_store.find("consent")
      expect(record.status).to eq("blocked")
      expect(record.blocked_reason).to eq("consent")
    end

    it ":revoked never fires" do
      book!
      granted
      contact_store.set_revoked(tenant: "acme", customer: "c-1", now: now)
      summary = engine.run
      expect(summary[:fired]).to eq(0)
      expect(summary[:blocked_reasons]).to eq("revoked" => 1)
    end

    it ":unavailable blocks" do
      book!
      granted
      contact_store.mark_unavailable(tenant: "acme", customer: "c-1", now: now)
      summary = engine.run
      expect(summary[:blocked_reasons]).to eq("unavailable" => 1)
    end

    it "quiet hours defer — the record stays pending and the next pass fires it" do
      book!(at: now + 3600, id: "qh")
      granted
      quiet = Insika::AgentProfile.build(
        id: "store-support", model: "m",
        followup: { "arm" => "schedule",
                    "policy" => { "quiet_hours" => { "timezone" => "UTC", "start" => "13:00", "end" => "13:30" } } }
      )
      profiles = Insika::StaticProfileSource.new("store-support" => quiet)
      # pass 1 at 13:10 UTC — INSIDE the quiet window
      summary = engine(now: Time.iso8601("2026-08-14T13:10:00Z"), profiles: profiles).run
      expect(summary[:deferred]).to eq(1)
      expect(summary[:fired]).to eq(0)
      record = followup_store.find("qh")
      expect(record.status).to eq("pending") # the deferral IS the pending record

      # the next pass, outside quiet hours, fires it
      summary2 = engine(now: Time.iso8601("2026-08-15T12:00:00Z"), profiles: profiles).run
      expect(summary2[:fired]).to eq(1)
    end

    it "the frequency ceiling blocks the second send inside the window" do
      # policy allows 1/24h; one record already FIRED inside the window
      first = book!(id: "first", reason: "r1")
      followup_store.transition_fired(id: first.id, task_id: "t-1", now: now)
      book!(id: "second", reason: "r2")
      granted
      one_per_day = Insika::AgentProfile.build(
        id: "store-support", model: "m",
        followup: { "arm" => "schedule",
                    "policy" => { "max_frequency" => "1/24h" } }
      )

      summary = engine(profiles: Insika::StaticProfileSource.new("store-support" => one_per_day)).run
      expect(summary[:fired]).to eq(0)
      expect(summary[:blocked_reasons]).to eq("frequency" => 1)
      record = followup_store.find("second")
      expect(record.status).to eq("blocked")
      expect(record.blocked_reason).to eq("frequency")
    end

    it "a backlog fires at most the cap in ONE pass — the cap counts FIRES, never the scheduled time" do
      # three records for the same customer, all booked DAYS ago (they piled up
      # during a tick outage), all due at the same pass. cap 1/24h.
      seed_pending_pair(id: "a", at: now - 172_800, reason: "r1")
      seed_pending_pair(id: "b", at: now - 86_400, reason: "r2")
      seed_pending_pair(id: "c", at: now - 60, reason: "r3")
      granted
      one_per_day = Insika::AgentProfile.build(
        id: "store-support", model: "m",
        followup: { "arm" => "schedule", "policy" => { "max_frequency" => "1/24h" } }
      )

      summary = engine(profiles: Insika::StaticProfileSource.new("store-support" => one_per_day),
                       now: now + 4000).run

      # exactly ONE message to the customer in this pass — the old at-based
      # count read the scheduled times (all outside the window) and fired all 3.
      expect(summary[:fired]).to eq(1)
      expect(summary[:blocked_reasons]).to eq("frequency" => 2)
      expect(followup_store.find("a").status).to eq("fired")
      expect(followup_store.find("b").status).to eq("blocked")
      expect(followup_store.find("c").status).to eq("blocked")
    end

    it "dedup collapses the younger of a duplicate (customer, reason) pair" do
      older = book!(id: "older", reason: "pix pending")
      followup_store.transition_fired(id: older.id, task_id: "t-1", now: now)
      # a NEW pair may be scheduled again after the first fired (D7) — but a
      # second PENDING of the same pair (seeded outside the tool — the cron arm,
      # legacy data) must never fire while the older one is still pending:
      book!(id: "dup-a", at: now + 7200, reason: "cart")
      seed_pending_pair(id: "dup-b", at: now + 14_400, reason: "cart")
      granted

      summary = engine(now: now + 20_000).run
      expect(summary[:fired]).to eq(1)
      expect(summary[:blocked_reasons]).to eq("dedup" => 1)
      expect(followup_store.find("dup-a").status).to eq("fired")
      expect(followup_store.find("dup-b").status).to eq("blocked")
      expect(followup_store.find("dup-b").blocked_reason).to eq("dedup")
    end

    it "a malformed policy blocks with :policy_invalid (never a crash)" do
      broken = Insika::AgentProfile.build(
        id: "store-support", model: "m",
        followup: { "arm" => "schedule", "policy" => { "max_frequency" => "2/3w" } }
      )
      book!
      granted
      summary = engine(profiles: Insika::StaticProfileSource.new("store-support" => broken)).run
      expect(summary[:fired]).to eq(0)
      expect(summary[:blocked_reasons]).to eq("policy_invalid" => 1)
      expect(summary[:errors]).to eq(0)
    end

    it "a missing profile blocks with :policy_invalid" do
      book!
      granted
      summary = engine(profiles: Insika::StaticProfileSource.new).run
      expect(summary[:blocked_reasons]).to eq("policy_invalid" => 1)
    end
  end

  describe "E3 — silence ≠ outright refusal" do
    it "fires bump sends_without_reply; at the ceiling the state flips :unavailable" do
      # one record due per pass, so each fire is its own claim window
      book!(id: "a", at: now + 60, reason: "r1")
      book!(id: "b", at: now + 86_460, reason: "r2")
      book!(id: "c", at: now + 172_860, reason: "r3")
      granted

      pass1 = now + 100
      pass2 = now + 86_500
      pass3 = now + 172_900

      engine(now: pass1).run # fires "a" (count 1)
      engine(now: pass2).run # fires "b" (count 2)
      engine(now: pass3).run # fires "c" (count 3 -> :unavailable)

      cell = contact_store.get(tenant: "acme", customer: "c-1")
      expect(cell.sends_without_reply).to eq(3)
      expect(cell.state).to eq("unavailable")

      # the next record blocks
      book!(id: "d", at: pass3 + 60, reason: "r4")
      summary = engine(now: pass3 + 400).run
      expect(summary[:fired]).to eq(0)
      expect(summary[:blocked_reasons]).to eq("unavailable" => 1)
    end

    it "a fresh customer message reopens: :granted, counter reset, next pass fires an old pending" do
      book!(id: "a", at: now + 60, reason: "r1")
      granted
      engine(now: now + 100).run # fires "a" (count 1)

      later = now + 86_400
      engine(now: later + 100).run # nothing new due; the cell stays as-is
      cell = contact_store.get(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(1)

      # the customer speaks -> reopens (the SendMessage hook is C6; here the store
      # is flipped directly — the engine's side must honor it)
      contact_store.set_granted(tenant: "acme", customer: "c-1", now: later + 100)
      book!(id: "c", at: later + 10_000, reason: "r3")
      summary = engine(now: later + 10_100).run
      expect(summary[:fired]).to eq(1)
      expect(summary[:blocked]).to eq(0)
    end
  end

  describe "isolation" do
    it "a StoreError on ONE record aborts that record's transaction, the loop continues" do
      book!(id: "good", reason: "r1")
      book!(id: "bad", reason: "r2")
      granted

      # make the second record's fire raise: the transition_fired claim fails
      allow(followup_store).to receive(:transition_fired).and_wrap_original do |m, **args|
        if args[:id] == "bad"
          raise Insika::StoreError, "boom"
        end

        m.call(**args)
      end

      summary = engine.run
      expect(summary[:fired]).to eq(1)
      expect(summary[:errors]).to eq(1)
      expect(followup_store.find("good").status).to eq("fired")
      expect(followup_store.find("bad").status).to eq("pending")
    end

    it "a second worker gets {claimed: false}" do
      summary = engine.run
      expect(summary[:claimed]).to be(true)
      expect(engine.run[:claimed]).to be(false)
    end
  end
end
