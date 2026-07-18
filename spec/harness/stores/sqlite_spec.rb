# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "sqlite3" # the spec may require the gem; only the CORE has the lazy require rule
require_relative "../store_contract"

RSpec.describe Harness::Stores::SQLite do
  context "with :memory: database" do
    subject(:store) { described_class.new(path: ":memory:") }

    after { store.close }

    it_behaves_like "a harness store"
  end

  context "with a file in tmpdir" do
    subject(:store) { described_class.new(path: db_path) }

    let(:tmpdir) { Dir.mktmpdir }
    let(:db_path) { File.join(tmpdir, "harness-test.db") }

    after do
      store.close
      FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
    end

    it_behaves_like "a harness store"

    # The only backend-specific tests allowed (doc 01 §7).

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
        rescue Harness::StoreError
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

  describe "lazy require of the sqlite3 gem (doc 01 §8)" do
    it "require \"harness\" does not load the sqlite3 gem before the first new" do
      # Clean subprocess: within the suite the gem was already required by other
      # specs (random order), so we test in an isolated ruby. bundler/setup
      # activates the gems load path (async is a core dependency) but does NOT
      # require sqlite3 — only the backend's initialize does that.
      script = 'require "bundler/setup"; require "harness"; ' \
               "exit(defined?(SQLite3) ? 1 : 0)"
      ok = system(RbConfig.ruby, "-Ilib", "-e", script,
                  out: File::NULL, err: File::NULL)
      expect(ok).to be(true)
    end
  end
end
