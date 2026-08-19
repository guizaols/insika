# frozen_string_literal: true

require "spec_helper"

# the operator-mutation audit trail. Append-only, content-free by
# construction (DIGESTS, never values), capped per cell. A failed audit write
# is a no-op — it never breaks the mutation it describes.
RSpec.describe Insika::MemoryAuditStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Insika::Stores::Memory.new }
  let(:clock) { -> { Time.utc(2026, 8, 17, 12, 0, 0) } }

  def record(**kwargs)
    store.record(cell: "memory:acme:c-1", action: "put", actor: "studio",
                 key: "size", tenant: "acme", customer: "c-1", **kwargs)
  end

  it "record -> for_cell returns the coerced entry, most recent first" do
    first = store.record(cell: "memory:acme:c-1", action: "put", actor: "studio",
                         key: "size", tenant: "acme", customer: "c-1",
                         old_hash: nil, new_hash: "a1b", note: nil)
    second = store.record(cell: "memory:acme:c-1", action: "forget", actor: "studio",
                          key: "size", tenant: "acme", customer: "c-1", old_hash: "a1b")

    expect(first).to be_a(described_class::Entry)
    expect(first.action).to eq("put")
    expect(first.actor).to eq("studio")
    expect(first.key).to eq("size")

    entries = store.for_cell("memory:acme:c-1")
    expect(entries.map(&:action)).to eq(%w[forget put]) # most recent first
    expect(entries.first.old_hash).to eq("a1b")
  end

  it "the 201st entry drops the oldest (cap bounds growth)" do
    210.times { |i| store.record(cell: "memory:acme:c-1", action: "put", actor: "x",
                                 key: "k#{i}", tenant: "acme", customer: "c-1") }
    entries = store.for_cell("memory:acme:c-1", limit: 1000)
    expect(entries.size).to eq(described_class::MAX_PER_CELL)
    expect(entries.map(&:key)).to include("k209")
    expect(entries.map(&:key)).not_to include("k0")
  end

  it "digest is deterministic and differs for different values; JSON shape hashes its JSON" do
    a = described_class.digest({ "size" => "M" })
    expect(described_class.digest({ "size" => "M" })).to eq(a)
    expect(described_class.digest({ "size" => "L" })).not_to eq(a)
    expect(described_class.digest("M")).to eq(Digest::SHA256.hexdigest("M"))
    expect(described_class.digest({ "size" => "M" })).not_to eq(described_class.digest("M"))
  end

  it "a raising backend is a no-op (audit never breaks the command)" do
    failing = described_class.new(store: Class.new do
      def get(*) = raise(StandardError, "boom")
      def set(*) = raise(StandardError, "boom")
      def list(*) = raise(StandardError, "boom")
    end.new)
    expect(failing.record(cell: "memory:acme:c-1", action: "put", actor: "x")).to be_nil
    expect(failing.for_cell("memory:acme:c-1")).to eq([])
  end

  it "cells don't mix" do
    record
    store.record(cell: "memory:globex:c-9", action: "put", actor: "studio", key: "k",
                 tenant: "globex", customer: "c-9")
    expect(store.for_cell("memory:acme:c-1").size).to eq(1)
    expect(store.for_cell("memory:globex:c-9").size).to eq(1)
  end

  it "an empty cell -> []" do
    expect(store.for_cell("memory:acme:nobody")).to eq([])
  end

  it "clock is injectable for deterministic at" do
    scoped = described_class.new(store: backend, clock: clock)
    entry = scoped.record(cell: "memory:acme:c-1", action: "put", actor: "x")
    expect(entry.at).to eq("2026-08-17T12:00:00.000000Z")
  end
end