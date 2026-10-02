# frozen_string_literal: true

require_relative "../../../lib/insika/testing/store_contract"

# Runs only against a real server: PG_TEST_URL (CI sets it).
RSpec.describe "Insika::Stores::Postgres", if: ENV["PG_TEST_URL"] do
  let(:url) { ENV.fetch("PG_TEST_URL") }
  subject(:store) { Insika::Stores::Postgres.new(url: url) }

  before do
    Insika::Stores::Postgres.new(url: url).tap { |s| s.send(:with_conn) { |c| c.exec("TRUNCATE insika_kv") } }.close
  end

  after { store.close }

  it_behaves_like "an Insika store"

  it "does not load pg until a Postgres store is built" do
    out = `#{RbConfig.ruby} -Ilib -e 'require "insika"; print defined?(PG) ? "loaded" : "lazy"'`
    expect(out).to eq("lazy")
  end

  it_behaves_like "an Insika store safe for N workers" do
    let(:store_factory) { -> { Insika::Stores::Postgres.new(url: url, pool: 2) } }
  end

  # The pool gives two fibers of ONE process two connections: their read-check-write
  # must serialize exactly like two processes'.
  it "two fibers of one process claim a pending key exactly once" do
    require "async"
    store.set("jobs", "j", "pending")
    claims = Sync do |task|
      Array.new(4) do
        task.async do
          store.transaction do
            next false unless store.get("jobs", "j") == "pending"

            task.sleep(0.01)
            store.set("jobs", "j", "claimed")
            true
          end
        end
      end.map(&:wait)
    end
    expect(claims.count(true)).to eq(1)
  end

  # A row lock cannot cover a row that does not exist; the per-key advisory lock does.
  it "serializes a read-check-write on a missing key" do
    require "async"
    created = Sync do |task|
      Array.new(4) do
        task.async do
          store.transaction do
            next false unless store.get("once", "k").nil?

            task.sleep(0.01)
            store.set("once", "k", 1)
            true
          end
        end
      end.map(&:wait)
    end
    expect(created.count(true)).to eq(1)
  end

  it "a failed transaction rolls back and hands back a clean connection" do
    small = Insika::Stores::Postgres.new(url: url, pool: 1)
    expect { small.transaction { small.set("s", "k", 1); raise "boom" } }.to raise_error("boom")
    expect(small.get("s", "k")).to be_nil # same single connection, usable again
  ensure
    small&.close
  end

  it "reconnects after the server dropped the connection" do
    small = Insika::Stores::Postgres.new(url: url, pool: 1)
    small.set("s", "k", 1)
    pid = small.send(:with_conn, &:backend_pid)
    Insika::Stores::Postgres.new(url: url).tap { |o| o.send(:with_conn) { |c| c.exec_params("SELECT pg_terminate_backend($1)", [pid]) } }.close

    expect { small.get("s", "k") }.to raise_error(Insika::StoreError) # the call that hit the dead socket
    expect(small.get("s", "k")).to eq(1)                               # the next one reconnects
  ensure
    small&.close
  end

  # Each call that fails to connect must give its pool slot back, or a server
  # outage drains the pool and the process waits forever once it is back.
  it "keeps its pool slots through failed reconnects" do
    small = Insika::Stores::Postgres.new(url: url, pool: 2)
    small.instance_variable_set(:@url, "postgres://postgres:pg@127.0.0.1:1/postgres?connect_timeout=1")
    3.times { expect { small.get("s", "k") }.to raise_error(Insika::StoreError) }
    small.instance_variable_set(:@url, url)

    expect(small.get("s", "k")).to be_nil # would block forever on an empty pool
  ensure
    small&.close
  end

  # `return`/`break` out of the block skips COMMIT; the connection must not go
  # back to the pool inside an open transaction.
  it "a block left with return does not leave its transaction open" do
    small = Insika::Stores::Postgres.new(url: url, pool: 1)
    leave = ->(st) { st.transaction { st.set("s", "inside", 1); return :left } }
    expect(leave.call(small)).to eq(:left)
    small.set("s", "after", 2)

    other = Insika::Stores::Postgres.new(url: url)
    expect(other.get("s", "after")).to eq(2)
    other.close
  ensure
    small&.close
  end

  # SQLite queued a plain write behind any open transaction. A plain set landing
  # between a transaction's read and its write would otherwise be overwritten.
  it "a plain set waits for a transaction that read the same key" do
    require "async"
    store.set("meters", "hits", 0)
    Sync do |task|
      reader = task.async do
        store.transaction do
          current = store.get("meters", "hits")
          task.sleep(0.05)
          store.set("meters", "hits", current + 1)
        end
      end
      task.sleep(0.01)
      store.set("meters", "hits", 100) # lands after the transaction commits
      reader.wait
    end
    expect(store.get("meters", "hits")).to eq(100)
  end

  # Two transactions locking the same two keys in opposite order: Postgres
  # aborts one as a deadlock; it re-runs, like SQLite's wait-then-run.
  it "re-runs a transaction the server aborted as a deadlock" do
    require "async"
    store.set("d", "a", 0)
    store.set("d", "b", 0)
    results = Sync do |task|
      [%w[a b], %w[b a]].map do |first, second|
        task.async do
          store.transaction do
            store.get("d", first)
            task.sleep(0.05)
            store.set("d", second, store.get("d", second) + 1)
          end
          :ok
        end
      end.map(&:wait)
    end
    expect(results).to eq(%i[ok ok])
    expect(store.get("d", "a") + store.get("d", "b")).to eq(2)
  end

  it "refuses a pool smaller than one connection" do
    expect { Insika::Stores::Postgres.new(url: url, pool: 0) }.to raise_error(ArgumentError)
  end

  it "a closed store raises instead of waiting" do
    closed = Insika::Stores::Postgres.new(url: url)
    closed.close
    expect { closed.get("s", "k") }.to raise_error(Insika::StoreError, /closed/)
  end

  # Two saves of the same next turn: the second must fail the monotonic guard,
  # as it does on SQLite, instead of overwriting the first.
  it "lets only one of two concurrent saves of the same checkpoint turn through" do
    require "async"
    checkpoints = Insika::CheckpointStore.new(store: store)
    make = ->(turn) { Insika::Checkpoint.new(task_id: "t1", turn: turn, session_id: nil, agent_id: "a", messages: [], completed_side_effects: [], created_at: Time.now.utc.iso8601) }
    checkpoints.save(make.call(1))
    results = Sync do |task|
      Array.new(2) do
        task.async do
          checkpoints.save(make.call(2))
          :saved
        rescue ArgumentError
          :refused
        end
      end.map(&:wait)
    end
    expect(results.sort).to eq(%i[refused saved])
  end

  # A purge must lock the task key the trace recorders read, so a trace being
  # recorded either lands before the purge (and is purged) or sees no task.
  it "TaskStore#delete reads the task key before removing anything" do
    tasks = Insika::TaskStore.new(store: store)
    task = tasks.create(command: { type: "x", payload: {}, meta: {} })
    seen = []
    allow(store).to receive(:get).and_wrap_original { |m, *a| seen << [:get, a[0]]; m.call(*a) }
    allow(store).to receive(:list).and_wrap_original { |m, *a| seen << [:list, a[0]]; m.call(*a) }
    tasks.delete(task.id)

    expect(seen.first).to eq([:get, "tasks"])
  end

  # Two rotations for one tenant at once must end with ONE active token: each
  # revokes what it saw, so they have to run one after the other.
  it "two concurrent rotations leave the tenant a single active token" do
    require "async"
    tokens = Insika::TokenStore.new(store: store)
    tokens.issue(tenant_id: "acme")
    Sync do |task|
      2.times.map { task.async { tokens.rotate(tenant_id: "acme") } }.each(&:wait)
    end
    active = tokens.active_token_ids.count do |id|
      store.get(Insika::TokenStore::SCOPE, tokens.send(:record_key, id))["tenant_id"] == "acme"
    end
    expect(active).to eq(1)
  end
end
