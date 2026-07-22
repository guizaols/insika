# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::DelegationStore do
  let(:store) { described_class.new(store: Harness::Stores::Memory.new) }

  def create(**over)
    defaults = { parent_task_id: "pt", parent_session_id: "ps", parent_agent: "parent",
                 child_agent: "researcher", child_task_id: "ct", child_session_id: "cs", depth: 1 }
    store.create(**defaults.merge(over))
  end

  it "creates a :dispatched record with the lineage" do
    d = create
    expect(d.status).to eq(:dispatched)
    expect(d.parent_task_id).to eq("pt")
    expect(d.child_task_id).to eq("ct")
    expect(d.result).to be_nil
  end

  it "finds by child task id (the terminal hook's lookup)" do
    create(child_task_id: "ct-42")
    expect(store.find_by_child_task("ct-42").child_task_id).to eq("ct-42")
    expect(store.find_by_child_task("nope")).to be_nil
  end

  describe "mark_completed (dispatched -> completed)" do
    it "captures the result" do
      d = create
      done = store.mark_completed(d.id, result: "the answer")
      expect(done.status).to eq(:completed)
      expect(done.result).to eq("the answer")
    end

    it "captures an error" do
      d = create
      expect(store.mark_completed(d.id, error: "boom").error).to eq("boom")
    end

    it "is idempotent (a second call is a no-op, does not clobber)" do
      d = create
      store.mark_completed(d.id, result: "first")
      again = store.mark_completed(d.id, result: "second")
      expect(again.result).to eq("first")
    end
  end

  describe "claim_delivery (completed -> delivered, atomic)" do
    it "returns true once, then false (at-most-once claim)" do
      d = create
      store.mark_completed(d.id, result: "x")
      expect(store.claim_delivery(d.id)).to be(true)
      expect(store.claim_delivery(d.id)).to be(false) # already delivered
      expect(store.find(d.id).status).to eq(:delivered)
    end

    it "returns false for a still-dispatched record (nothing captured yet)" do
      d = create
      expect(store.claim_delivery(d.id)).to be(false)
    end
  end

  describe "#undelivered (recovery scan)" do
    it "returns dispatched + completed, excludes delivered" do
      a = create(child_task_id: "a")
      b = create(child_task_id: "b")
      c = create(child_task_id: "c")
      store.mark_completed(b.id, result: "x")
      store.mark_completed(c.id, result: "y")
      store.claim_delivery(c.id) # delivered

      ids = store.undelivered.map(&:id)
      expect(ids).to contain_exactly(a.id, b.id)
    end
  end
end
