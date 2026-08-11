# frozen_string_literal: true

require "spec_helper"

# The lifecycle is the whole contract: what the boot sweep may
# re-drive, and what it must never touch.
RSpec.describe Insika::OutboxStore do
  let(:store) { described_class.new(store: Insika::Stores::Memory.new) }

  def create(**over)
    defaults = { channel: "relay", to: "5511999998888", task_id: "t-1", session_id: "relay:5511999998888",
                 payload: { "content" => "pronto!" } }
    store.create(**defaults.merge(over))
  end

  it "creates a :pending record carrying the recipient and the body" do
    d = create
    expect(d.status).to eq(:pending)
    expect(d.to).to eq("5511999998888")
    expect(d.payload["content"]).to eq("pronto!")
    expect(d.attempts).to eq(0)
  end

  describe "claim (pending -> delivering, atomic)" do
    it "returns true once, then false" do
      d = create
      expect(store.claim(d.id)).to be(true)
      expect(store.claim(d.id)).to be(false)
      expect(store.find(d.id).status).to eq(:delivering)
    end

    it "refuses a record that is already terminal" do
      d = create
      store.claim(d.id)
      store.mark_delivered(d.id)
      expect(store.claim(d.id)).to be(false)
    end
  end

  it "counts attempts and keeps the recipient's own words" do
    d = create
    store.claim(d.id)
    store.record_attempt(d.id, error: "HTTP 503")
    store.record_attempt(d.id, error: "HTTP 503")
    expect(store.find(d.id).attempts).to eq(2)
    expect(store.find(d.id).last_error).to eq("HTTP 503")
    expect(store.find(d.id).status).to eq(:delivering)
  end

  it "clears the last error when it finally lands" do
    d = create
    store.claim(d.id)
    store.record_attempt(d.id, error: "HTTP 503")
    done = store.mark_delivered(d.id)
    expect(done.status).to eq(:delivered)
    expect(done.last_error).to be_nil
    expect(done.attempts).to eq(2) # the failed one plus the one that worked
  end

  it "is idempotent on mark_delivered (no double counting)" do
    d = create
    store.claim(d.id)
    store.mark_delivered(d.id)
    expect(store.mark_delivered(d.id).attempts).to eq(1)
  end

  # This is the at-most-once guarantee, expressed as a query: only a record nobody
  # ever claimed may be re-driven. A `delivering` record belonged to a process that
  # died, and whether its POST landed is unknowable — replaying it is the duplicate
  # the claim exists to prevent.
  describe "pending (what the boot sweep re-drives)" do
    it "returns only unclaimed records" do
      fresh = create
      claimed = create(task_id: "t-2")
      store.claim(claimed.id)
      done = create(task_id: "t-3")
      store.claim(done.id)
      store.mark_delivered(done.id)
      dead = create(task_id: "t-4")
      store.claim(dead.id)
      store.mark_failed(dead.id, error: "gave up")

      expect(store.pending.map(&:id)).to eq([fresh.id])
    end
  end

  it "raises NotFoundError for an unknown id" do
    expect { store.mark_delivered("nope") }.to raise_error(Insika::NotFoundError)
    expect(store.find("nope")).to be_nil
  end
end
