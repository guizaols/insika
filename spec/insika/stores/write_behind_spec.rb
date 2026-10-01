# frozen_string_literal: true

require "async"
require_relative "../../../lib/insika/testing/store_contract"

RSpec.describe Insika::Stores::WriteBehind do
  let(:inner) { Insika::Stores::Memory.new }
  let(:store) { described_class.new(inner, scopes: %w[traces], interval: 60) }

  context "as a store" do
    subject { store }

    it_behaves_like "an Insika store"
  end

  # Diagnostic writes leave the turn: they sit in memory until the flusher writes
  # them, so the turn never waits for the file's write lock on their account.
  it "keeps a buffered scope's write in memory until a flush, and reads it back meanwhile" do
    Sync do
      store.set("traces", "s1", [1])

      expect(inner.get("traces", "s1")).to be_nil
      expect(store.get("traces", "s1")).to eq([1])
      store.flush
      expect(inner.get("traces", "s1")).to eq([1])
    end
  end

  # A trace is read-modify-write per tool call: several in one interval become
  # one write of the last value, not one write each.
  it "writes only the last value of a key that changed several times" do
    Sync do
      allow(inner).to receive(:set).and_call_original
      3.times { |i| store.set("traces", "s1", (store.get("traces", "s1") || []) + [i]) }
      store.flush

      expect(inner).to have_received(:set).with("traces", "s1", [0, 1, 2]).once
      expect(inner).to have_received(:set).once
    end
  end

  it "flushes everything pending in one transaction" do
    Sync do
      allow(inner).to receive(:transaction).and_call_original
      store.set("traces", "a", 1)
      store.set("traces", "b", 2)
      store.flush

      expect(inner).to have_received(:transaction).once
      expect([inner.get("traces", "a"), inner.get("traces", "b")]).to eq([1, 2])
    end
  end

  it "writes other scopes straight through" do
    Sync do
      store.set("sessions", "s1", { "x" => 1 })

      expect(inner.get("sessions", "s1")).to eq({ "x" => 1 })
    end
  end

  it "writes through when there is no reactor to flush later" do
    store.set("traces", "s1", [1])

    expect(inner.get("traces", "s1")).to eq([1])
  end

  it "flushes on its own after the interval" do
    quick = described_class.new(inner, scopes: %w[traces], interval: 0.01)
    Sync do |task|
      quick.set("traces", "s1", [1])
      task.sleep(0.05)

      expect(inner.get("traces", "s1")).to eq([1])
    end
  end

  it "a delete drops the pending value too" do
    Sync do
      store.set("traces", "s1", [1])
      store.delete("traces", "s1")
      store.flush

      expect(store.get("traces", "s1")).to be_nil
      expect(inner.get("traces", "s1")).to be_nil
    end
  end

  it "lists pending keys with the stored ones" do
    Sync do
      inner.set("traces", "a", 1)
      store.set("traces", "b", 2)

      expect(store.list("traces")).to eq(%w[a b])
    end
  end

  it "matches a scope's tenant suffix to its base name" do
    Sync do
      store.set("traces:acme", "s1", [1])

      expect(inner.get("traces:acme", "s1")).to be_nil
    end
  end

  # Backpressure, not loss: past the cap the write goes straight to the store.
  it "writes through once the pending set is full" do
    small = described_class.new(inner, scopes: %w[traces], interval: 60, max_pending: 1)
    Sync do
      small.set("traces", "a", 1)
      small.set("traces", "b", 2)

      expect(inner.get("traces", "a")).to be_nil
      expect(inner.get("traces", "b")).to eq(2)
    end
  end

  it "a key already pending keeps being deferred when the pending set is full" do
    small = described_class.new(inner, scopes: %w[traces], interval: 60, max_pending: 1)
    Sync do
      small.set("traces", "a", 1)
      small.set("traces", "a", 2)

      expect(small.get("traces", "a")).to eq(2)
      small.flush
      expect(inner.get("traces", "a")).to eq(2)
    end
  end

  it "a read hands out a copy, like the backends: changing it does not change the pending value" do
    Sync do
      store.set("traces", "s1", [1])
      store.get("traces", "s1") << 2

      expect(store.get("traces", "s1")).to eq([1])
    end
  end

  it "keeps the values for the next flush when a flush fails" do
    Sync do
      store.set("traces", "s1", [1])
      allow(inner).to receive(:transaction).and_raise(Insika::StoreError, "locked")
      expect { store.flush }.not_to raise_error

      allow(inner).to receive(:transaction).and_call_original
      store.flush
      expect(inner.get("traces", "s1")).to eq([1])
    end
  end

  it "a newer value written during a failed flush wins over the retried one" do
    Sync do
      store.set("traces", "s1", [1])
      allow(inner).to receive(:transaction) do
        store.set("traces", "s1", [1, 2])
        raise Insika::StoreError, "locked"
      end
      store.flush
      allow(inner).to receive(:transaction).and_call_original
      store.flush

      expect(inner.get("traces", "s1")).to eq([1, 2])
    end
  end
end
