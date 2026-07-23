# frozen_string_literal: true

# Contract suite for Insika::Store (doc 01 §7).
# Every backend passes EXACTLY this suite (L2: the suite is honest —
# a test that passes on Memory passes on SQLite).
# The including group must define `store` (empty, ready backend), e.g.:
#
#   RSpec.describe Insika::Stores::Memory do
#     subject(:store) { described_class.new }
#     it_behaves_like "an Insika store"
#   end
#
# Do not include backend-specific cases here (file durability,
# WAL, concurrency) — those belong to task 4.
RSpec.shared_examples "an Insika store" do
  describe "#get / #set (round-trip)" do
    it "C1 preserves Hash with string keys" do # C1
      store.set("s", "k", { "a" => 1, "b" => [1, 2] })
      expect(store.get("s", "k")).to eq({ "a" => 1, "b" => [1, 2] })
    end

    it "C2 preserves Array" do # C2
      store.set("s", "k", [1, "x", true, nil])
      expect(store.get("s", "k")).to eq([1, "x", true, nil])
    end

    it "C3 preserves String" do # C3
      store.set("s", "k", "texto")
      expect(store.get("s", "k")).to eq("texto")
    end

    it "C4 preserves Integer" do # C4
      store.set("s", "k", 42)
      value = store.get("s", "k")
      expect(value).to eq(42)
      expect(value).to be_a(Integer)
    end

    it "C5 preserves Float" do # C5
      store.set("s", "k", 3.14)
      value = store.get("s", "k")
      expect(value).to eq(3.14)
      expect(value).to be_a(Float)
    end

    it "C6 preserves booleans" do # C6
      store.set("s", "t", true)
      store.set("s", "f", false)
      expect(store.get("s", "t")).to be(true)
      expect(store.get("s", "f")).to be(false)
    end

    it "C7 preserves nil written without exception" do # C7
      store.set("s", "k", nil)
      expect(store.get("s", "k")).to be_nil
    end

    it "C8 converts Symbols (keys and values) to Strings" do # C8
      store.set("s", "k", { chave: :valor })
      expect(store.get("s", "k")).to eq({ "chave" => "valor" })
    end

    it "C9 returns nil for an absent key, never an exception" do # C9
      expect(store.get("s", "nao-existe")).to be_nil
    end

    it "C10 overwrites silently (last-write-wins)" do # C10
      store.set("s", "k", "primeiro")
      store.set("s", "k", "segundo")
      expect(store.get("s", "k")).to eq("segundo")
    end

    it "C11 set returns the same object passed in (not the round-trip)" do # C11
      obj = { "a" => 1 }
      expect(store.set("s", "k", obj)).to equal(obj)
    end
  end

  describe "#delete" do
    it "C12 removes existing and returns true" do # C12
      store.set("s", "k", 1)
      expect(store.delete("s", "k")).to be(true)
      expect(store.get("s", "k")).to be_nil
    end

    it "C13 returns false for a nonexistent key" do # C13
      expect(store.delete("s", "k")).to be(false)
    end
  end

  describe "#list" do
    it "C14 returns scope keys sorted lexicographically" do # C14
      store.set("s", "b", 1)
      store.set("s", "a", 1)
      store.set("s", "c", 1)
      expect(store.list("s")).to eq(%w[a b c])
    end

    it "C15 filters by prefix with start_with? (not include?)" do # C15
      store.set("s", "task:1", 1)
      store.set("s", "task:2", 1)
      store.set("s", "checkpoint:1", 1)
      store.set("s", "my-task:1", 1) # trap: contains "task:" but does not start with it
      expect(store.list("s", "task:")).to eq(%w[task:1 task:2])
    end

    it "C16 returns [] for an empty scope" do # C16
      expect(store.list("s")).to eq([])
    end

    it "sorts lexicographically, not numerically" do # edge case 2
      store.set("s", "task:10", 1)
      store.set("s", "task:2", 1)
      expect(store.list("s", "task:")).to eq(%w[task:10 task:2])
    end
  end

  describe "scope isolation" do
    it "C17 keeps scopes independent in get/list/delete" do # C17
      store.set("s1", "k", 1)
      store.set("s2", "k", 2)

      expect(store.get("s1", "k")).to eq(1)
      expect(store.get("s2", "k")).to eq(2)
      expect(store.list("s1")).to eq(%w[k])

      store.delete("s1", "k")
      expect(store.get("s2", "k")).to eq(2)
    end
  end

  describe "#transaction" do
    it "C18 returns the block's value" do # C18
      expect(store.transaction { 42 }).to eq(42)
    end

    it "C19 commits the block's writes" do # C19
      store.transaction { store.set("s", "k", "commitado") }
      expect(store.get("s", "k")).to eq("commitado")
    end

    it "C20 does a real rollback of set AND delete when the block raises" do # C20
      store.set("s", "manter", "antigo")
      store.set("s", "apagar", "existe")

      expect do
        store.transaction do
          store.set("s", "manter", "novo")
          store.delete("s", "apagar")
          raise "boom"
        end
      end.to raise_error("boom")

      # all the block's effects undone
      expect(store.get("s", "manter")).to eq("antigo")
      expect(store.get("s", "apagar")).to eq("existe")
    end

    it "C21 reuses the outer transaction when nested" do # C21
      store.set("s", "k", "antigo")

      expect do
        store.transaction do
          store.transaction { store.set("s", "k", "novo") }
          raise "boom"
        end
      end.to raise_error("boom")

      # outer rollback undoes the inner set (no nesting error)
      expect(store.get("s", "k")).to eq("antigo")
    end
  end

  describe "serialization errors" do
    it "C22 raises StoreError and does not write a non-serializable value" do # C22
      expect do
        store.set("s", "k", Object.new)
      end.to raise_error(Insika::StoreError)
      expect(store.get("s", "k")).to be_nil
    end
  end
end
