# frozen_string_literal: true

require "spec_helper"

# RFC-0033 C4 — the follow-up schedule records: the store owns the
# pending|fired|cancelled|blocked states (never written by a consumer) and the
# (customer, reason) scans. It holds no policy (C2) and no contact cells (C3).
RSpec.describe Insika::FollowupStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }

  let(:now) { Time.iso8601("2026-08-14T12:00:00Z") }

  def create!(at: now + 3600, agent: "store-support", customer: "c-1", reason: "pix pending", arm: "schedule", id: SecureRandom.uuid, **rest)
    store.create(tenant: "acme", agent: agent, customer: customer, session_id: "s-1",
                 at: at, reason: reason, arm: arm, id: id, now: now, **rest)
  end

  # a record with a PAST scheduled `at` (a backlog, legacy data) — create
  # refuses, so the direct backend path (the cron arm's spelling).
  def seed_pending(id:, at:)
    backend.set("followups", "acme:store-support:c-1:#{(at).iso8601}:#{id}",
                { "id" => id, "tenant" => "acme", "agent" => "store-support",
                  "customer" => "c-1", "session_id" => "s-1",
                  "at" => at.iso8601, "reason" => "r-#{id}", "arm" => "schedule",
                  "status" => "pending", "task_id" => nil, "blocked_reason" => nil,
                  "transport" => "channel:whatsapp", "created_at" => now.iso8601,
                  "updated_at" => now.iso8601, "fired_at" => nil })
  end

  describe "#create" do
    it "creates a pending record with the given fields" do
      record = create!(transport: "channel:whatsapp")
      expect(record.status).to eq("pending")
      expect(record.at).to eq((now + 3600).iso8601)
      expect(record.tenant).to eq("acme")
      expect(record.arm).to eq("schedule")
      expect(record.transport).to eq("channel:whatsapp")
      expect(record.session_id).to eq("s-1")
      expect(store.find(record.id)).to eq(record)
    end

    it "a past `at` is refused ('the follow-up would already be due')" do
      expect { create!(at: now - 1) }.to raise_error(Insika::ValidationError, /already be due/)
    end

    it "a duplicate pending (agent, customer, reason) raises naming the prior id" do
      first = create!(reason: "pix pending")
      expect { create!(reason: "pix pending") }.to raise_error(Insika::ValidationError, /#{first.id}/)
    end

    it "a cancelled pair may be scheduled again (D7)" do
      first = create!(reason: "pix pending")
      store.cancel(id: first.id)
      second = create!(reason: "pix pending")
      expect(second.id).not_to eq(first.id)
      expect(second.status).to eq("pending")
    end

    it "a blank tenant lands in the 'platform' cell (purge prefix alignment)" do
      record = store.create(tenant: nil, agent: "a", customer: "c-1", session_id: nil,
                            at: now + 3600, reason: "r", arm: "schedule", id: "x", now: now)
      expect(store.find("x").tenant).to eq("platform")
      expect(store.purge(tenant: "platform")).to eq(1)
    end
  end

  describe "the state machine" do
    it "transition_fired: pending -> fired, WITH task_id" do
      record = create!
      fired = store.transition_fired(id: record.id, task_id: "task-1")
      expect(fired.status).to eq("fired")
      expect(fired.task_id).to eq("task-1")
      expect(store.find(record.id).status).to eq("fired")
    end

    it "a second claim raises (a fired record fires once — E1)" do
      record = create!
      store.transition_fired(id: record.id, task_id: "task-1")
      expect { store.transition_fired(id: record.id, task_id: "task-2") }
        .to raise_error(ArgumentError)
    end

    it "block: pending -> blocked, carrying the failing rule" do
      record = create!
      blocked = store.block(id: record.id, reason: :frequency)
      expect(blocked.status).to eq("blocked")
      expect(blocked.blocked_reason).to eq("frequency")
    end

    it "block from a non-pending record raises" do
      record = create!
      store.transition_fired(id: record.id, task_id: "t")
      expect { store.block(id: record.id, reason: :frequency) }.to raise_error(ArgumentError)
    end

    it "cancel: pending -> cancelled" do
      record = create!
      expect(store.cancel(id: record.id).status).to eq("cancelled")
      expect(store.find(record.id).status).to eq("cancelled")
    end

    it "cancel of an already-cancelled record is a no-op (idempotent)" do
      record = create!
      store.cancel(id: record.id)
      expect { store.cancel(id: record.id) }.not_to raise_error
      expect(store.find(record.id).status).to eq("cancelled")
    end

    it "cancel of a fired record raises" do
      record = create!
      store.transition_fired(id: record.id, task_id: "t")
      expect { store.cancel(id: record.id) }.to raise_error(ArgumentError)
    end

    it "find on a nonexistent id -> nil; cancel -> NotFoundError" do
      expect(store.find("nope")).to be_nil
      expect { store.cancel(id: "nope") }.to raise_error(Insika::NotFoundError)
    end
  end

  describe "#due" do
    it "returns ONLY pending-and-due records, oldest first (at, then id)" do
      older = create!(at: now + 60, id: "a", reason: "r1")
      newer = create!(at: now + 120, id: "b", reason: "r2")
      future = create!(at: now + 3600, id: "c", reason: "r3")
      store.cancel(id: newer.id)

      expect(store.due(now: now + 200)).to eq([older])
      expect(store.due(now: now + 4000).map(&:id)).to contain_exactly("a", "c")
    end

    it "ties at the same `at` break by id" do
      create!(at: now + 60, id: "a", reason: "r1")
      create!(at: now + 60, id: "b", reason: "r2")
      expect(store.due(now: now + 4000).map(&:id)).to eq(%w[a b])
    end
  end

  describe "the scans" do
    it "pending_for? is true only for a pending record of the exact pair" do
      create!(reason: "pix pending")
      create!(reason: "cart abandoned")
      expect(store.pending_for?(tenant: "acme", agent: "store-support",
                                customer: "c-1", reason: "pix pending")).to be(true)
      expect(store.pending_for?(tenant: "acme", agent: "store-support",
                                customer: "c-1", reason: "cadastro")).to be(false)
      expect(store.pending_for?(tenant: "acme", agent: "other",
                                customer: "c-1", reason: "pix pending")).to be(false)
      expect(store.pending_for?(tenant: "zed", agent: "store-support",
                                customer: "c-1", reason: "pix pending")).to be(false)
    end

    it "pending_for? is false once the record leaves pending" do
      record = create!(reason: "pix pending")
      store.cancel(id: record.id)
      expect(store.pending_for?(tenant: "acme", agent: "store-support",
                                customer: "c-1", reason: "pix pending")).to be(false)
    end

    it "fired_in_window counts the customer's fired records inside the window" do
      create!(reason: "a", id: "r1")
      create!(reason: "b", id: "r2")
      create!(reason: "c", id: "r3", customer: "c-2")
      %w[r1 r2 r3].each { |id| store.transition_fired(id: id, task_id: "t-#{id}", now: now) }

      expect(store.fired_in_window(tenant: "acme", customer: "c-1",
                                   since: now - 3600)).to eq(2)
      expect(store.fired_in_window(tenant: "acme", customer: "c-2",
                                   since: now - 3600)).to eq(1)
      expect(store.fired_in_window(tenant: "acme", customer: "c-1",
                                   since: now + 3601)).to eq(0)
    end

    it "fired_in_window counts the FIRE time, never the scheduled time (review fix)" do
      # both booked days ago (the backlog case — a past `at` can only exist
      # via the direct path, since create refuses); only the FIRST fired
      seed_pending(id: "old", at: now - 172_800)
      seed_pending(id: "fresh", at: now - 3600)
      store.transition_fired(id: "old", task_id: "t", now: now)

      # the scheduled-time window would count 0 (old's `at` is outside) —
      # the fire-time window counts 1
      expect(store.fired_in_window(tenant: "acme", customer: "c-1",
                                   since: now - 3600)).to eq(1)
    end
  end

  describe "purge paths" do
    it "purge_customer reaches exactly that customer's records and nothing else" do
      create!(id: "a", customer: "c-1", reason: "r1")
      create!(id: "b", customer: "c-1", reason: "r2")
      create!(id: "c", customer: "c-2", reason: "r3")
      expect(store.purge_customer(tenant: "acme", customer: "c-1")).to eq(2)
      expect(store.find("a")).to be_nil
      expect(store.find("b")).to be_nil
      expect(store.find("c")).not_to be_nil
    end

    it "purge removes every record of the tenant" do
      create!(id: "a", tenant: "acme", reason: "r1")
      create!(id: "b", tenant: "zed", reason: "r2")
      expect(store.purge(tenant: "acme")).to eq(1)
      expect(store.find("a")).to be_nil
      expect(store.find("b")).not_to be_nil
    end

    it "delete_older_than takes TERMINAL records + past-due zombies, leaves a future pending" do
      cutoff = now + 86_400
      # a terminal record whose scheduled time already passed
      old = create!(id: "old", at: now + 60, reason: "r1")
      store.transition_fired(id: "old", task_id: "t", now: now)
      # a ZOMBIE: still pending, its at has passed (quiet hours deferred it past
      # the point of no return — retention ages it out rather than firing late)
      zombie = create!(id: "zombie", at: now + 60, reason: "r2")
      # a healthy future pending, scheduled past the cutoff
      future = create!(id: "future", at: now + 172_800, reason: "r3")

      expect(store.delete_older_than(cutoff)).to eq(2)
      expect(store.find("old")).to be_nil
      expect(store.find("zombie")).to be_nil
      expect(store.find("future")).not_to be_nil
      expect(old.updated_at).not_to be_nil
      expect(zombie.updated_at).not_to be_nil
    end
  end
end
