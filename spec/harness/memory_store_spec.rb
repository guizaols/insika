# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::MemoryStore do
  subject(:store) { described_class.new(store: backend) }

  let(:backend) { Harness::Stores::Memory.new }

  describe "facts (profile layer)" do
    it "put_fact + get_fact round-trip" do
      fact = store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(fact.key).to eq("plano")
      expect(fact.value).to eq("premium")
      expect(fact.updated_at).to be_a(String)
      expect(store.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
    end

    it "upsert: last-write-wins" do
      store.put_fact(tenant: "acme", key: "plano", value: "basic")
      store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(store.get_fact(tenant: "acme", key: "plano").value).to eq("premium")
      expect(store.facts(tenant: "acme").size).to eq(1)
    end

    it "get_fact nonexistent -> nil" do
      expect(store.get_fact(tenant: "acme", key: "nope")).to be_nil
    end

    it "facts ordered by key" do
      store.put_fact(tenant: "acme", key: "zeta", value: "z")
      store.put_fact(tenant: "acme", key: "alpha", value: "a")
      expect(store.facts(tenant: "acme").map(&:key)).to eq(%w[alpha zeta])
    end

    it "forget_fact removes and returns whether it existed" do
      store.put_fact(tenant: "acme", key: "plano", value: "premium")
      expect(store.forget_fact(tenant: "acme", key: "plano")).to be(true)
      expect(store.get_fact(tenant: "acme", key: "plano")).to be_nil
    end

    it "normalizes symbol->string in the value" do
      fact = store.put_fact(tenant: "acme", key: "k", value: :sym)
      expect(fact.value).to eq("sym")
    end
  end

  describe "notes (notes layer)" do
    it "add_note + notes most-recent-first" do
      store.add_note(tenant: "acme", text: "primeira", at: "2026-01-01T00:00:00Z")
      store.add_note(tenant: "acme", text: "segunda", at: "2026-01-02T00:00:00Z")
      expect(store.notes(tenant: "acme").map(&:text)).to eq(%w[segunda primeira])
    end

    it "limit caps (the N most recent)" do
      3.times { |i| store.add_note(tenant: "acme", text: "n#{i}", at: "2026-01-0#{i + 1}T00:00:00Z") }
      expect(store.notes(tenant: "acme", limit: 2).map(&:text)).to eq(%w[n2 n1])
    end

    it "note carries id and created_at" do
      note = store.add_note(tenant: "acme", text: "oi", id: "fixed", at: "2026-01-01T00:00:00Z")
      expect(note.id).to eq("fixed")
      expect(note.created_at).to eq("2026-01-01T00:00:00Z")
    end
  end

  describe "tenant isolation" do
    it "tenant A does not see B's memory" do
      store.put_fact(tenant: "a", key: "k", value: "va")
      store.add_note(tenant: "a", text: "na")
      expect(store.facts(tenant: "b")).to eq([])
      expect(store.notes(tenant: "b")).to eq([])
      expect(store.get_fact(tenant: "b", key: "k")).to be_nil
    end

    it "tenant nil/empty -> _default scope (does not break)" do
      store.put_fact(tenant: nil, key: "k", value: "v")
      expect(store.get_fact(tenant: nil, key: "k").value).to eq("v")
      # _default is a tenant distinct from any other
      expect(store.get_fact(tenant: "acme", key: "k")).to be_nil
    end
  end
end
