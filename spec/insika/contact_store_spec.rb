# frozen_string_literal: true

require "spec_helper"

#   — the durable contact-state cell per (tenant, customer). One
# derived cell, never a transition log (D2): granted | revoked | unavailable,
# the sends-without-reply counter and the last outbound timestamp. The store
# holds no policy and no follow-ups; the firer and the inbound hook own the
# transformations.
RSpec.describe Insika::ContactStore do
  let(:backend) { Insika::Stores::Memory.new }
  subject(:store) { described_class.new(store: backend) }

  describe "#get" do
    it "returns nil until the cell exists (absent = never messaged — the :consent block)" do
      expect(store.get(tenant: "acme", customer: "c-1")).to be_nil
    end

    it "returns the cell after a write" do
      store.set_granted(tenant: "acme", customer: "c-1")
      cell = store.get(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(0)
      expect(cell.updated_at).not_to be_nil
    end

    it "nil customer -> nil (an untagged conversation has no cell)" do
      expect(store.get(tenant: "acme", customer: nil)).to be_nil
    end
  end

  describe "the three writers" do
    it "set_granted reopens: state granted + sends_without_reply reset (D2)" do
      store.bump_outbound(tenant: "acme", customer: "c-1")
      store.set_revoked(tenant: "acme", customer: "c-1")
      store.set_granted(tenant: "acme", customer: "c-1")
      cell = store.get(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(0)
    end

    it "set_revoked is immediate and permanent until the customer speaks" do
      store.set_granted(tenant: "acme", customer: "c-1")
      store.set_revoked(tenant: "acme", customer: "c-1")
      expect(store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
    end

    it "mark_unavailable flips the state (silence reached the ceiling)" do
      store.set_granted(tenant: "acme", customer: "c-1")
      store.mark_unavailable(tenant: "acme", customer: "c-1")
      expect(store.get(tenant: "acme", customer: "c-1").state).to eq("unavailable")
    end
  end

  describe "#consent (— the schedule tool's write)" do
    it "creates the cell when absent (the first consent is granted)" do
      cell = store.consent(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(0)
    end

    it "NEVER lifts :unavailable — only a customer message reopens (D2)" do
      store.bump_outbound(tenant: "acme", customer: "c-1")
      store.bump_outbound(tenant: "acme", customer: "c-1")
      store.mark_unavailable(tenant: "acme", customer: "c-1")

      cell = store.consent(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("unavailable")
      expect(cell.sends_without_reply).to eq(2) # the counter is untouched
    end

    it "NEVER resets sends_without_reply on a granted cell" do
      store.bump_outbound(tenant: "acme", customer: "c-1")
      cell = store.consent(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(1)
    end

    it "raises on :revoked — an opt-out is permanent" do
      store.set_revoked(tenant: "acme", customer: "c-1")
      expect { store.consent(tenant: "acme", customer: "c-1") }
        .to raise_error(Insika::ValidationError, /opted out/)
    end
  end

  describe "#bump_outbound" do
    it "increments sends_without_reply and stamps last_outbound_at" do
      now = Time.iso8601("2026-08-14T10:00:00Z")
      store.bump_outbound(tenant: "acme", customer: "c-1", now: now)
      store.bump_outbound(tenant: "acme", customer: "c-1", now: now + 60)
      cell = store.get(tenant: "acme", customer: "c-1")
      expect(cell.sends_without_reply).to eq(2)
      expect(cell.last_outbound_at).to eq((now + 60).iso8601)
    end

    it "creates the cell when absent (the firer checks the GO before bumping)" do
      store.bump_outbound(tenant: "acme", customer: "c-1")
      expect(store.get(tenant: "acme", customer: "c-1").state).to eq("granted")
    end
  end

  describe "tenant isolation" do
    it "two tenants hold disjoint cells" do
      store.set_revoked(tenant: "acme", customer: "c-1")
      store.set_granted(tenant: "zed", customer: "c-1")
      expect(store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
      expect(store.get(tenant: "zed", customer: "c-1").state).to eq("granted")
    end
  end

  describe "the blank-tenant edge" do
    it "a blank tenant lands in the 'platform' cell (purge prefix alignment)" do
      store.set_granted(tenant: nil, customer: "c-1")
      expect(store.get(tenant: "", customer: "c-1")).not_to be_nil
      expect(store.get(tenant: "platform", customer: "c-1").state).to eq("granted")
    end

    it "purge('platform') reaches the blank-tenant cell" do
      store.set_granted(tenant: nil, customer: "c-1")
      store.set_granted(tenant: "acme", customer: "c-2")
      expect(store.purge(tenant: "platform")).to eq(1)
      expect(store.get(tenant: "platform", customer: "c-1")).to be_nil
      expect(store.get(tenant: "acme", customer: "c-2")).not_to be_nil
    end
  end

  describe "purge paths" do
    it "delete removes one customer's cell" do
      store.set_granted(tenant: "acme", customer: "c-1")
      expect(store.delete(tenant: "acme", customer: "c-1")).to be(true)
      expect(store.get(tenant: "acme", customer: "c-1")).to be_nil
      expect(store.delete(tenant: "acme", customer: "c-1")).to be(false)
    end

    it "purge removes every cell of the tenant" do
      store.set_granted(tenant: "acme", customer: "c-1")
      store.set_granted(tenant: "acme", customer: "c-2")
      store.set_granted(tenant: "zed", customer: "c-1")
      expect(store.purge(tenant: "acme")).to eq(2)
      expect(store.get(tenant: "acme", customer: "c-1")).to be_nil
      expect(store.get(tenant: "zed", customer: "c-1")).not_to be_nil
    end

    it "delete_older_than touches only old cells" do
      cutoff = Time.iso8601("2026-08-14T00:00:00Z")
      store.set_granted(tenant: "acme", customer: "old", now: cutoff - 86_400)
      store.set_granted(tenant: "acme", customer: "new", now: cutoff + 3600)
      expect(store.delete_older_than(cutoff)).to eq(1)
      expect(store.get(tenant: "acme", customer: "old")).to be_nil
      expect(store.get(tenant: "acme", customer: "new")).not_to be_nil
    end
  end
end
