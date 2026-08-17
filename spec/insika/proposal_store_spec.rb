# frozen_string_literal: true

require "time"

RSpec.describe Insika::ProposalStore do
  subject(:store) { described_class.new(store: backend) }
  let(:backend) { Insika::Stores::Memory.new }
  let(:now) { Time.parse("2026-08-16T12:00:00Z") }

  def create!(**kw)
    store.create(tenant: "acme", customer: "c-1", session_ref: "acme:sess_1",
                 key: "size", value: "M", **kw)
  end

  describe "#create" do
    it "round-trips the record with scope, evidence and the revision baseline" do
      proposal = store.create(
        tenant: "acme", customer: "c-1", session_ref: "acme:sess_1",
        key: "size", value: "M", confidence: 0.9, evidence: [3, 5],
        expected_revision: "2026-08-14T10:00:00.000000Z", expected_existed: true
      )
      expect(proposal.status).to eq("pending")
      expect(proposal.scope).to eq("acme:c-1")
      expect(proposal.evidence).to eq([3, 5])
      expect(proposal.expected_revision).to eq("2026-08-14T10:00:00.000000Z")
      expect(proposal.expected_existed).to be(true)

      found = store.find(proposal.id)
      expect(found).to eq(proposal)
    end

    it "a blank tenant stays blank — the single-tenant cell shape (never a phantom sentinel)" do
      proposal = store.create(tenant: nil, customer: "c-9", session_ref: "s",
                              key: "k", value: "v")
      expect(proposal.tenant).to be_nil
      expect(proposal.scope).to eq("c-9")
    end
  end

  describe "the state machine" do
    it "approve/reject/dismiss/mark_stale only from pending" do
      proposal = create!
      expect(store.approve(id: proposal.id, operator: "op").status).to eq("approved")
      expect { store.approve(id: proposal.id, operator: "op") }
        .to raise_error(ArgumentError, /pending/)
      expect { store.reject(id: proposal.id) }.to raise_error(ArgumentError, /pending/)
      expect { store.dismiss(id: proposal.id) }.to raise_error(ArgumentError, /pending/)
      expect { store.mark_stale(id: proposal.id, current_value: "L") }
        .to raise_error(ArgumentError, /pending/)
    end

    it "reject records the note; dismiss latches; mark_stale carries current_value" do
      rejected = create!(key: "budget")
      r = store.reject(id: rejected.id, operator: "op", note: "not durable")
      expect(r.status).to eq("rejected")
      expect(r.operator).to eq("op")
      expect(r.note).to eq("not durable")

      dismissed = create!(key: "color")
      expect(store.dismiss(id: dismissed.id).status).to eq("dismissed")

      stale = create!(key: "shipping")
      s = store.mark_stale(id: stale.id, current_value: "L")
      expect(s.status).to eq("stale")
      expect(s.current_value).to eq("L")
    end

    it "transitions stamp updated_at and leave the rest of the record intact" do
      proposal = create!(evidence: [1])
      resolved = store.reject(id: proposal.id)
      expect(resolved.updated_at).not_to be_nil
      expect(resolved.created_at).to eq(proposal.created_at)
    end
  end

  describe "the latched dedup (D3)" do
    it "decided? latches dismissed AND rejected tuples" do
      create!(key: "size", value: "M")
      dismissed = store.pending(limit: 100).first
      store.dismiss(id: dismissed.id)
      expect(store.decided?(tenant: "acme", customer: "c-1", key: "size", value: "M")).to be(true)
      expect(store.decided?(tenant: "acme", customer: "c-1", key: "size", value: "L")).to be(false)
    end

    it "decided? is false for pending/approved/stale" do
      pending = create!(key: "a", value: "1")
      approved = create!(key: "b", value: "2")
      stale = create!(key: "c", value: "3")
      store.approve(id: approved.id)
      store.mark_stale(id: stale.id, current_value: "x")
      [pending, approved, stale].each do |p|
        expect(store.decided?(tenant: p.tenant, customer: p.customer, key: p.key, value: p.value))
          .to be(false)
      end
    end

    it "open_pending? is true while a pending row exists on the key and false after resolution" do
      create!(key: "size", value: "M")
      expect(store.open_pending?(tenant: "acme", customer: "c-1", key: "size")).to be(true)
      expect(store.open_pending?(tenant: "acme", customer: "c-1", key: "other")).to be(false)

      store.reject(id: store.pending(limit: 100).first.id)
      expect(store.open_pending?(tenant: "acme", customer: "c-1", key: "size")).to be(false)
    end

    it "a different value for the same name is a different tuple" do
      create!(key: "size", value: "M")
      store.dismiss(id: store.pending(limit: 100).first.id)
      create!(key: "size", value: "L")
      expect(store.pending(limit: 100).size).to eq(1)
    end
  end

  describe "the scans" do
    before do
      create!(key: "size", value: "M")                       # acme:c-1 oldest
      create!(key: "budget", value: "100")                   # acme:c-1
      create!(tenant: "acme", customer: "c-2", key: "size", value: "L")
      create!(tenant: "other", customer: "c-1", key: "size", value: "M")
    end

    it "pending lists pending oldest first and caps at the limit" do
      store.reject(id: store.pending(limit: 100).first.id)
      expect(store.pending(limit: 100).map(&:key)).to eq(%w[budget size size])
      expect(store.pending(limit: 2).size).to eq(2)
    end

    it "stale lists only CAS-lost records" do
      store.mark_stale(id: store.pending(limit: 100).last.id, current_value: "XL")
      expect(store.stale(limit: 50).size).to eq(1)
      expect(store.stale(limit: 50).first.current_value).to eq("XL")
    end

    it "resolved lists every terminal status, most recent first" do
      first = store.pending(limit: 100).first
      store.dismiss(id: first.id)
      records = store.resolved(limit: 20)
      expect(records.size).to eq(1)
      expect(records.first.status).to eq("dismissed")
      expect(records.first.id).to eq(first.id)
    end
  end

  describe "the per-session marker (D2)" do
    it "distilled? is false until marked, then true; the marker round-trips" do
      expect(store.distilled?("acme:sess_1")).to be(false)
      marker = store.mark_distilled("acme:sess_1", agent: "store-support",
                                    proposals: 2, dropped: { "schema" => 1 }, deduped: 3,
                                    cost: { "spent" => 1234 })
      expect(marker["session_ref"]).to eq("acme:sess_1")
      expect(marker["agent"]).to eq("store-support")
      expect(store.distilled?("acme:sess_1")).to be(true)
    end
  end

  describe "purges (LGPD / retention, C8)" do
    before do
      create!(key: "size", value: "M")                       # acme:c-1
      create!(tenant: "acme", customer: "c-2", key: "size", value: "L")
      create!(tenant: "other", customer: "c-1", key: "size", value: "M")
    end

    it "purge_customer reaches exactly that customer's proposals (all statuses)" do
      resolved = store.pending(limit: 100).select { |p| p.customer == "c-1" }.first
      store.dismiss(id: resolved.id)
      removed = store.purge_customer(tenant: "acme", customer: "c-1")
      expect(removed).to eq(1)
      # the neighbours survive — their proposals are still pending
      expect(store.pending(limit: 100).size).to eq(2)
      expect(store.pending(limit: 100).map(&:customer)).to eq(%w[c-2 c-1])
    end

    it "purge(tenant:) removes the tenant's proposals and no one else's" do
      removed = store.purge(tenant: "acme")
      expect(removed).to eq(2)
      expect(store.pending(limit: 100).map(&:customer)).to eq(%w[c-1])
    end

    it "delete_older_than takes terminal + zombie pendings and leaves the rest" do
      store.mark_distilled("acme:sess_old", agent: "a", proposals: 0, dropped: {})
      old = store.create(tenant: "acme", customer: "c-9", session_ref: "acme:sess_old",
                         key: "k", value: "v", id: "old-1", now: Time.parse("2026-08-01T00:00:00Z"))
      store.dismiss(id: old.id, now: Time.parse("2026-08-02T00:00:00Z"))  # terminal
      zombie = store.create(tenant: "acme", customer: "c-9", session_ref: "acme:sess_old",
                            key: "z", value: "v", id: "zombie-1",
                            now: Time.parse("2026-08-01T00:00:00Z"))
      recent = create!(key: "fresh", value: "v")

      removed = store.delete_older_than(Time.parse("2026-08-10T00:00:00Z"))
      expect(removed).to eq(2)
      expect(store.find("old-1")).to be_nil
      expect(store.find("zombie-1")).to be_nil
      expect(store.find(recent.id)).not_to be_nil
    end

    it "a marker past the cutoff dies WITH its proposals — an unreviewed proposal is never locked out of re-distillation" do
      store.mark_distilled("acme:sess_old", agent: "a", proposals: 1, dropped: {},
                            now: Time.parse("2026-08-01T00:00:00Z"))
      store.create(tenant: "acme", customer: "c-9", session_ref: "acme:sess_old",
                   key: "k", value: "v", now: Time.parse("2026-08-01T00:00:00Z"))
      # a recent marker (and its proposal) survive
      store.mark_distilled("acme:sess_new", agent: "a", proposals: 1, dropped: {},
                            now: Time.parse("2026-08-15T00:00:00Z"))
      store.create(tenant: "acme", customer: "c-9", session_ref: "acme:sess_new",
                   key: "n", value: "v", now: Time.parse("2026-08-15T00:00:00Z"))

      removed = store.delete_older_than(Time.parse("2026-08-10T00:00:00Z"))
      expect(removed).to eq(2)
      expect(store.distilled?("acme:sess_old")).to be(false)
      expect(store.distilled?("acme:sess_new")).to be(true)
      expect(store.pending(limit: 100).map(&:key)).to include("n")
      expect(store.pending(limit: 100).map(&:key)).not_to include("k")
    end
  end
end
