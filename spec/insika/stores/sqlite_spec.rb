# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "logger"
require "stringio"
require "sqlite3" # the spec may require the gem; only the CORE has the lazy require rule
require_relative "../../../lib/insika/testing/store_contract"

RSpec.describe Insika::Stores::SQLite do
  context "with :memory: database" do
    subject(:store) { described_class.new(path: ":memory:") }

    after { store.close }

    it_behaves_like "an Insika store"
  end

  context "with a file in tmpdir" do
    subject(:store) { described_class.new(path: db_path) }

    let(:tmpdir) { Dir.mktmpdir }
    let(:db_path) { File.join(tmpdir, "insika-test.db") }

    after do
      store.close
      FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
    end

    it_behaves_like "an Insika store"

    # Multi-worker safety: separate connections on the
    # SAME file, which is exactly how N Falcon workers reach one database.
    # The :memory: context cannot include this — two handles on :memory: are
    # two databases.
    it_behaves_like "an Insika store safe for N workers" do
      let(:store_factory) { -> { described_class.new(path: db_path) } }
    end

    # The only backend-specific tests allowed.

    # Under Litestream the app must not checkpoint: its autocheckpoints race
    # Litestream's own and the WAL grows without bound.
    it "turns off SQLite's autocheckpoint when asked, keeping the default otherwise" do
      quiet = described_class.new(path: db_path, autocheckpoint: false)
      pragma = ->(st) { st.instance_variable_get(:@db).get_first_value("PRAGMA wal_autocheckpoint") }

      expect([pragma.call(quiet), pragma.call(store)]).to eq([0, 1000])
    ensure
      quiet&.close
    end

    # A prefix list used to SELECT the whole scope and filter in Ruby, holding
    # the GVL, so its cost grew with the database and starved the reactor under
    # load. It must seek the primary key instead.
    it "lists a prefix by seeking the primary key, not scanning the scope" do
      plan = store.instance_variable_get(:@db)
                  .execute("EXPLAIN QUERY PLAN #{described_class::LIST_PREFIX_SQL}", ["s", "a:", "a;"])
                  .map(&:last).join(" ")

      expect(plan).to match(/SEARCH kv USING COVERING INDEX kv_scope_key \(scope=\? AND key>\? AND key<\?\)/)
    end

    # A store call holds the GVL for its whole duration, so a slow one stalls every
    # fiber in the process. The log names the call, the scope and the caller.
    it "logs store calls at or above slow_ms with the caller, and nothing when off" do
      io = StringIO.new
      slow = described_class.new(path: db_path, slow_ms: 0, logger: Logger.new(io))
      slow.set("s", "k", 1)
      slow.list("s", "k")
      store.get("s", "k")

      expect(io.string).to match(/slow store set scope=s \d+\.\d ms at .*sqlite_spec\.rb:\d+/)
        .and match(/slow store list scope=s /)
        .and satisfy { |log| !log.include?("store get") }
    ensure
      slow&.close
    end

    # A slow write is either waiting for the file's lock or holding it: the batch
    # line splits the two and says how much each batch wrote, and from which scopes.
    it "logs a slow write batch with its size, bytes, lock wait and commit time" do
      io = StringIO.new
      slow = described_class.new(path: db_path, slow_ms: 0, logger: Logger.new(io))
      slow.set("tasks", "k", { "v" => "x" * 100 })
      slow.delete("tasks", "k")

      expect(io.string).to match(
        /slow store batch writes=1 bytes=1\d\d wait=\d+\.\d ms exec=\d+\.\d ms commit=\d+\.\d ms scopes=tasks:1/
      ).and match(/slow store batch writes=1 bytes=0 /)
    ensure
      slow&.close
    end

    it "logs no batch line when slow_ms is off" do
      io = StringIO.new
      quiet = described_class.new(path: db_path, logger: Logger.new(io))
      quiet.set("tasks", "k", 1)

      expect(io.string).to be_empty
    ensure
      quiet&.close
    end

    # The table used to be WITHOUT ROWID: every row carried its value inside the
    # key b-tree, so listing keys read the values too. A file in that layout is
    # rebuilt on open into a rowid table plus a (scope, key) index, data intact.
    it "rebuilds a WITHOUT ROWID table into a rowid table with a key index" do
      store.close
      legacy = File.join(tmpdir, "legacy.db")
      raw = SQLite3::Database.new(legacy)
      raw.execute_batch(<<~SQL)
        CREATE TABLE kv (scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                         updated_at TEXT NOT NULL, PRIMARY KEY (scope, key)) WITHOUT ROWID;
        INSERT INTO kv VALUES ('s', 'a', '1', 't'), ('s', 'b', '{"x":2}', 't'), ('o', 'a', '"z"', 't');
      SQL
      raw.close

      reopened = described_class.new(path: legacy)
      sql = reopened.instance_variable_get(:@db).get_first_value("SELECT sql FROM sqlite_master WHERE name = 'kv'")
      index = reopened.instance_variable_get(:@db).get_first_value("SELECT name FROM sqlite_master WHERE name = 'kv_scope_key'")

      expect([sql.include?("WITHOUT ROWID"), index, reopened.list("s"), reopened.get("s", "b"), reopened.get("o", "a")])
        .to eq([false, "kv_scope_key", %w[a b], { "x" => 2 }, "z"])
    ensure
      reopened&.close
    end

    it "is durable: data survives close + reopen on the same file" do
      store.set("s", "k", { "a" => 1 })
      store.transaction { store.set("s", "t", "commitado") }
      store.close

      reopened = described_class.new(path: db_path)
      expect(reopened.get("s", "k")).to eq({ "a" => 1 })
      expect(reopened.get("s", "t")).to eq("commitado")
      reopened.close
    end

    it "enables WAL mode on the file (PRAGMA journal_mode == 'wal')" do
      store.set("s", "k", 1) # ensures the file exists

      inspect_db = SQLite3::Database.new(db_path)
      mode = inspect_db.get_first_value("PRAGMA journal_mode")
      inspect_db.close

      expect(mode).to eq("wal")
    end

    # Regression: multi-PROCESS boot (N Falcon workers) opening the SAME
    # file at the same time. The `PRAGMA journal_mode = WAL` + DDL contend on the
    # write lock; without `busy_timeout` set BEFORE, the 2nd process would hit
    # "database is locked" at the start. All processes must open without error.
    it "concurrent multi-process boot does not raise 'database is locked'" do
      skip "fork unavailable on this platform" unless Process.respond_to?(:fork)

      start = File.join(tmpdir, "go")
      shared = File.join(tmpdir, "concurrent-boot.db")
      pids = 8.times.map do
        fork do
          sleep 0.002 until File.exist?(start) # opens near-simultaneously (maximizes the race)
          db = described_class.new(path: shared)
          db.get("s", "k")
          db.close
          exit!(0)
        rescue Insika::StoreError
          exit!(1)
        end
      end
      File.write(start, "go")
      codes = pids.map { |pid| Process.wait2(pid).last.exitstatus }

      expect(codes).to all(eq(0))
    end

    it "N fibers writing + concurrent reader without SQLITE_BUSY" do
      require "async"

      Async do |task|
        writers = 8.times.map do |i|
          task.async do
            20.times { |n| store.transaction { store.set("scope-#{i}", "k#{n}", n) } }
          end
        end
        reader = task.async do
          50.times { store.list("scope-0") }
        end
        (writers + [reader]).each(&:wait)
      end

      expect(store.list("scope-3").length).to eq(20)
      expect(store.list("scope-0").length).to eq(20)
    end

    # Group commit: writes that arrive while the process waits for the file's
    # write lock share the transaction that gets it, so N workers on one file
    # take the lock once per batch instead of once per write.
    describe "group commit" do
      def with_lock_held_elsewhere
        blocker = SQLite3::Database.new(db_path)
        blocker.execute("BEGIN IMMEDIATE")
        Async do |task|
          yield task
          task.sleep(0.05) # the writers are now queued behind the lock
          blocker.commit
        end
      ensure
        blocker&.close
      end

      it "commits the writes queued behind a held lock together, each one durable" do
        require "async"
        store.set("g", "warm", 0) # opens the connection's schema before the lock is taken
        db = store.instance_variable_get(:@db)
        allow(db).to receive(:commit).and_call_original
        writers = nil

        with_lock_held_elsewhere do |task|
          writers = 5.times.map { |i| task.async { store.set("g", "k#{i}", i) } }
        end

        expect(writers.map(&:wait)).to eq([0, 1, 2, 3, 4])
        expect(db).to have_received(:commit).once
        expect(described_class.new(path: db_path).get("g", "k4")).to eq(4)
      end

      it "fails only the write that failed, not the others in its batch" do
        require "async"
        store.set("g", "warm", 0)
        ok = bad = nil

        with_lock_held_elsewhere do |task|
          ok = task.async { store.set("g", "fine", 1) }
          bad = task.async { store.set(nil, "broken", 2) } # scope is NOT NULL
        end

        expect(ok.wait).to eq(1)
        expect { bad.wait }.to raise_error(Insika::StoreError)
        expect(store.get("g", "fine")).to eq(1)
      end

      it "a leader stopped while waiting for the lock does not strand the writes queued behind it" do
        require "async"
        store.set("g", "warm", 0)
        follower = nil

        with_lock_held_elsewhere do |task|
          leader = task.async { store.set("g", "leader", 1) }
          follower = task.async { store.set("g", "follower", 2) }
          task.sleep(0.01)
          leader.stop
        end

        expect(follower.wait).to eq(2)
        expect(store.get("g", "follower")).to eq(2)
      end

      # A write-behind flush must ride the same batch as the turn's writes: a
      # transaction of its own would take the file's lock once more per flush.
      it "set_all joins the writes queued behind the lock instead of opening its own transaction" do
        require "async"
        store.set("g", "warm", 0)
        db = store.instance_variable_get(:@db)
        allow(db).to receive(:commit).and_call_original
        turn = flush = nil

        with_lock_held_elsewhere do |task|
          turn = task.async { store.set("tasks", "t1", 1) }
          flush = task.async { store.set_all([["traces", "a", [1]], ["traces", "b", [2]]]) }
        end

        expect([turn.wait, flush.wait]).to eq([1, 2])
        expect(db).to have_received(:commit).once
        expect([store.get("traces", "a"), store.get("traces", "b")]).to eq([[1], [2]])
      end

      it "set_all inside an explicit transaction writes in that transaction" do
        require "async"
        Sync do
          store.transaction { store.set_all([["traces", "a", [1]]]) }
        end

        expect(store.get("traces", "a")).to eq([1])
      end

      it "set_all inside a transaction does not wait on a leader that waits on that transaction" do
        require "async"
        other = nil
        Sync do |task|
          Async::Task.current.with_timeout(2) do
            store.transaction do
              other = task.async { store.set("x", "b", 1) } # leads, then waits for this transaction
              store.set_all([["traces", "a", [1]]])
            end
            other.wait
          end
        end

        expect([store.get("traces", "a"), store.get("x", "b")]).to eq([[1], 1])
      end

      it "answers each delete in a batch on its own" do
        require "async"
        store.set("g", "there", 1)
        here = gone = nil

        with_lock_held_elsewhere do |task|
          here = task.async { store.delete("g", "there") }
          gone = task.async { store.delete("g", "never") }
        end

        expect([here.wait, gone.wait]).to eq([true, false])
      end
    end

    it "serializes two concurrent transactions on the same scope (no failed BEGIN IMMEDIATE)" do
      require "async"

      Async do |task|
        a = task.async { store.transaction { store.set("s", "a", 1) } }
        b = task.async { store.transaction { store.set("s", "b", 2) } }
        [a, b].each(&:wait)
      end

      expect(store.get("s", "a")).to eq(1)
      expect(store.get("s", "b")).to eq(2)
    end
  end

  describe "lazy require of the sqlite3 gem" do
    it "require \"insika\" does not load the sqlite3 gem before the first new" do
      # Clean subprocess: within the suite the gem was already required by other
      # specs (random order), so we test in an isolated ruby. bundler/setup
      # activates the gems load path (async is a core dependency) but does NOT
      # require sqlite3 — only the backend's initialize does that.
      script = 'require "bundler/setup"; require "insika"; ' \
               "exit(defined?(SQLite3) ? 1 : 0)"
      ok = system(RbConfig.ruby, "-Ilib", "-e", script,
                  out: File::NULL, err: File::NULL)
      expect(ok).to be(true)
    end
  end
end
