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
end
