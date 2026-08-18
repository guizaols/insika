# frozen_string_literal: true

# Contract suite for Insika::Store, exported for third-party
# backends — a gem like `insika-pg` writes its spec against THIS
# file, not against a read of stores/sqlite.rb:
#
#   require "insika/testing/store_contract"
#
#   RSpec.describe Insika::Stores::PG do
#     subject(:store) { described_class.new(url:) }
#     it_behaves_like "an Insika store"
#   end
#
# Two groups, on purpose:
#
# - "an Insika store" — universal; every backend passes EXACTLY it (L2: the
#   suite is honest — a test that passes on Memory passes on SQLite). The
#   including group defines `store` (an empty, ready backend).
# - "an Insika store safe for N workers" — OPT-IN; the multi-worker half. The
#   including group ALSO defines `store_factory`, a callable returning ANOTHER
#   connection to the SAME underlying backend. A backend that cannot serialize
#   transactions across connections must not include it — Memory is the
#   canonical example, and a single-connection backend has nothing to prove.
#   Anything that wants to sit under `WEB_CONCURRENCY > 1` has to.
#
# Do not include backend-specific cases here (file durability, WAL, boot
# races) — those belong to the backend's own spec.
RSpec.shared_examples "an Insika store" do
  describe "#get / #set (round-trip)" do
    it " preserves Hash with string keys" do #
      store.set("s", "k", { "a" => 1, "b" => [1, 2] })
      expect(store.get("s", "k")).to eq({ "a" => 1, "b" => [1, 2] })
    end

    it " preserves Array" do #
      store.set("s", "k", [1, "x", true, nil])
      expect(store.get("s", "k")).to eq([1, "x", true, nil])
    end

    it " preserves String" do #
      store.set("s", "k", "texto")
      expect(store.get("s", "k")).to eq("texto")
    end

    it " preserves Integer" do #
      store.set("s", "k", 42)
      value = store.get("s", "k")
      expect(value).to eq(42)
      expect(value).to be_a(Integer)
    end

    it " preserves Float" do #
      store.set("s", "k", 3.14)
      value = store.get("s", "k")
      expect(value).to eq(3.14)
      expect(value).to be_a(Float)
    end

    it " preserves booleans" do #
      store.set("s", "t", true)
      store.set("s", "f", false)
      expect(store.get("s", "t")).to be(true)
      expect(store.get("s", "f")).to be(false)
    end

    it " preserves nil written without exception" do #
      store.set("s", "k", nil)
      expect(store.get("s", "k")).to be_nil
    end

    it " converts Symbols (keys and values) to Strings" do #
      store.set("s", "k", { key: :value })
      expect(store.get("s", "k")).to eq({ "key" => "value" })
    end

    it " returns nil for an absent key, never an exception" do #
      expect(store.get("s", "missing-key")).to be_nil
    end

    it " overwrites silently (last-write-wins)" do #
      store.set("s", "k", "first")
      store.set("s", "k", "second")
      expect(store.get("s", "k")).to eq("second")
    end

    it " set returns the same object passed in (not the round-trip)" do #
      obj = { "a" => 1 }
      expect(store.set("s", "k", obj)).to equal(obj)
    end
  end

  describe "#delete" do
    it " removes existing and returns true" do #
      store.set("s", "k", 1)
      expect(store.delete("s", "k")).to be(true)
      expect(store.get("s", "k")).to be_nil
    end

    it " returns false for a nonexistent key" do #
      expect(store.delete("s", "k")).to be(false)
    end
  end

  describe "#list" do
    it " returns scope keys sorted lexicographically" do #
      store.set("s", "b", 1)
      store.set("s", "a", 1)
      store.set("s", "c", 1)
      expect(store.list("s")).to eq(%w[a b c])
    end

    it " filters by prefix with start_with? (not include?)" do #
      store.set("s", "task:1", 1)
      store.set("s", "task:2", 1)
      store.set("s", "checkpoint:1", 1)
      store.set("s", "my-task:1", 1) # trap: contains "task:" but does not start with it
      expect(store.list("s", "task:")).to eq(%w[task:1 task:2])
    end

    it " returns [] for an empty scope" do #
      expect(store.list("s")).to eq([])
    end

    it "sorts lexicographically, not numerically" do # edge case 2
      store.set("s", "task:10", 1)
      store.set("s", "task:2", 1)
      expect(store.list("s", "task:")).to eq(%w[task:10 task:2])
    end
  end

  describe "#scopes" do
    it " returns scope names sorted lexicographically" do #
      store.set("zeta", "k", 1)
      store.set("alpha", "k", 1)
      store.set("alpha:child", "k", 1)
      expect(store.scopes).to eq(["alpha", "alpha:child", "zeta"])
    end

    it " filters by prefix with start_with? (not include?)" do #
      store.set("s", "k", 1)
      store.set("s:child", "k", 1)
      store.set("s2", "k", 1) # trap: contains "s" but does not start with "s:"
      expect(store.scopes("s:")).to eq(["s:child"])
    end

    it " returns [] when nothing matches (or the store is empty)" do #
      expect(store.scopes("nope")).to eq([])
      expect(store.scopes).to eq([])
    end
  end

  describe "scope isolation" do
    it " keeps scopes independent in get/list/delete" do #
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
    it " returns the block's value" do #
      expect(store.transaction { 42 }).to eq(42)
    end

    it " commits the block's writes" do #
      store.transaction { store.set("s", "k", "commitado") }
      expect(store.get("s", "k")).to eq("commitado")
    end

    it " does a real rollback of set AND delete when the block raises" do #
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

    it " reuses the outer transaction when nested" do #
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
    it " raises StoreError and does not write a non-serializable value" do #
      expect do
        store.set("s", "k", Object.new)
      end.to raise_error(Insika::StoreError)
      expect(store.get("s", "k")).to be_nil
    end
  end
end

# Multi-worker safety. Every claim (outbox, delegation
# sweep, recovery) is a read-check-write inside `transaction` — on SQLite that is
# atomic because the backend opens BEGIN IMMEDIATE; a backend whose transaction
# only yields passes all 22 cases above and still double-claims under two
# workers, silently. These cases close that hole, across REAL concurrent
# connections (threads, each on its own handle from `store_factory`).
#
# The `sleep` inside each transaction is deliberate: it holds the read state
# open long enough that a backend without isolation ALWAYS lets a second
# connection through, while a correct backend serializes the writers. Without
# it a wrong backend could pass by scheduling luck — the failure relies on.
RSpec.shared_examples "an Insika store safe for N workers" do
  # Starts N threads, each holding its OWN connection to the same backend,
  # releases them together, and returns each block's value. Connections are
  # closed on the way out when the backend has a #close.
  def with_concurrent_connections(n, &blk)
    ready = Queue.new
    go = Queue.new
    threads = n.times.map do
      Thread.new do
        conn = store_factory.call
        ready << true
        go.pop # hold every connection at the line, then release them together
        blk.call(conn)
      ensure
        conn.close if conn.respond_to?(:close)
      end
    end
    n.times { ready.pop }
    go.close # a closed queue pops nil immediately: the starting gun
    threads.map(&:value)
  end

  # The outbox/delegation claim, verbatim in shape: read the status, and only
  # the connection that still sees "pending" may flip it. A correct backend
  # serializes the transactions, so exactly ONE of the 8 observes "pending".
  it "claims a pending key exactly once across concurrent connections" do
    store.set("jobs", "job:1", "pending")

    claims = with_concurrent_connections(8) do |conn|
      conn.transaction do
        next unless conn.get("jobs", "job:1") == "pending"

        sleep 0.01 # hold the read open: a wrong backend lets everyone through
        conn.set("jobs", "job:1", "claimed")
        true
      end
    end.count(true)

    expect(claims).to eq(1)
    expect(store.get("jobs", "job:1")).to eq("claimed")
  end

  # The lost-update shape the claim generalizes from: read-modify-write of a
  # counter. A backend whose transaction yields without isolation drops
  # increments whenever two connections overlap.
  it "does not lose updates across concurrent connections" do
    store.set("meters", "hits", 0)
    connections = 4
    increments = 10

    with_concurrent_connections(connections) do |conn|
      increments.times do
        conn.transaction do
          current = conn.get("meters", "hits")
          sleep 0.001 # widen the window a wrong backend loses updates through
          conn.set("meters", "hits", current + 1)
        end
      end
    end

    expect(store.get("meters", "hits")).to eq(connections * increments)
  end
end
