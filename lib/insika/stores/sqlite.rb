# frozen_string_literal: true

require "json"
require "logger"
require "time"
require "async/semaphore"
require "async/promise"
require "zlib"

module Insika
  module Stores
    # SQLite backend — the production default.
    # A single kv table; the domain lives in the scopes. One handle per process,
    # writes in a transaction serialized by an Async::Semaphore.
    class SQLite
      include Store

      # Prepended per instance when slow_ms is set; see #initialize.
      module SlowLog
        %i[get set delete list scopes].each do |name|
          define_method(name) do |*args, &blk|
            t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = super(*args, &blk)
            ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
            report_slow(name, args.first, ms) if ms >= @slow_ms
            result
          end
        end

        private

        def report_slow(name, scope, ms)
          # up to 3 frames of the caller chain (the store method alone rarely says
          # which duty called it), innermost first
          chain = caller_locations(2, 40).reject { |l| l.path.end_with?("stores/sqlite.rb") }
                                        .select { |l| l.path.include?("/insika/") }.first(3)
          @slow_logger.warn(format("slow store %s scope=%s %.1f ms at %s", name, scope, ms,
                                   chain.map { |l| "#{File.basename(l.path)}:#{l.lineno}" }.join(" < ")))
        end
      end

      # A rowid table plus a (scope, key) index, not WITHOUT ROWID: values run to
      # tens of KB, and a WITHOUT ROWID table keeps each row inside the key
      # b-tree, so every key scan (list, the prefix ranges) read the values too.
      # The index holds only the keys; a value is read when it is asked for.
      # SQLite's own guidance: WITHOUT ROWID is for small rows.
      DDL = <<~SQL
        CREATE TABLE IF NOT EXISTS kv (
          scope      TEXT    NOT NULL,
          key        TEXT    NOT NULL,
          value      TEXT    NOT NULL,
          updated_at TEXT    NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS kv_scope_key ON kv (scope, key);
      SQL

      # The rebuild of a file still in the old layout: one transaction, so a crash
      # leaves the old table whole.
      REBUILD = <<~SQL
        CREATE TABLE kv_rowid (
          scope      TEXT    NOT NULL,
          key        TEXT    NOT NULL,
          value      TEXT    NOT NULL,
          updated_at TEXT    NOT NULL
        );
        INSERT INTO kv_rowid (scope, key, value, updated_at)
          SELECT scope, key, value, updated_at FROM kv ORDER BY scope, key;
        DROP TABLE kv;
        ALTER TABLE kv_rowid RENAME TO kv;
      SQL

      # JSON model types + Symbol (coerced to String on write).
      # Any other type is "garbage" and must be rejected. Identical to
      # Stores::Memory — both backends share the SAME type model
      # (the contract suite is honest).
      JSONABLE = [NilClass, TrueClass, FalseClass, Integer, Float,
                  String, Symbol].freeze
      private_constant :JSONABLE

      # lazy require: the core installs without the sqlite3 gem
      # when only Memory is used.
      # autocheckpoint: false when Litestream replicates this file — it owns the
      # checkpoints, and the app's own (every 1000 pages, per connection, N
      # workers) race it: the WAL grows past the database itself while Litestream's
      # checkpoint fails "database is locked". litestream.io/tips.
      # slow_ms: log every call that takes at least this long (nil = off, zero
      # cost). A call holds the GVL for its whole duration, so under a fiber
      # server a slow one stalls every turn in the process; the line names the
      # method, scope and Insika caller so the offender is found, not guessed.
      def initialize(path:, serializer: JSON, autocheckpoint: true, slow_ms: nil, logger: nil)
        require "sqlite3"

        if slow_ms
          @slow_ms = slow_ms
          @slow_logger = logger || Logger.new($stderr)
          singleton_class.prepend(SlowLog)
        end

        @serializer = serializer
        @db = SQLite3::Database.new(path)
        @write_semaphore = Async::Semaphore.new(1)
        @tx_owner = nil
        @pending_writes = []
        @flushing = false

        # Multi-process boot (N Falcon workers opening the SAME file at the
        # same time): `PRAGMA journal_mode = WAL` on a new file needs an
        # EXCLUSIVE lock and may return SQLITE_BUSY right then — the busy
        # timeout alone does NOT cover the journal-mode switch. Hence: timeout
        # FIRST (covers the DDL and the hot path) + retry with backoff around
        # the initialization (covers the WAL-switch race). Idempotent:
        # reopening already-in-WAL is a no-op.
        #
        # `busy_handler_timeout=`, NOT `busy_timeout=`: the C-level handler
        # sleeps holding the GVL, so a worker waiting on another PROCESS's
        # write lock would stall every fiber it is running for up to the full
        # timeout (measured: a waiter blocks the winner's own commit). The
        # Ruby-level handler sleeps in Ruby — the scheduler keeps the rest of
        # the worker breathing while this handle waits its turn.
        @db.busy_handler_timeout = 5_000
        with_busy_retry do
          @db.execute("PRAGMA journal_mode = WAL")
          @db.execute("PRAGMA synchronous = NORMAL")
          @db.execute("PRAGMA wal_autocheckpoint = 0") unless autocheckpoint
          rebuild_without_rowid!
          @db.execute_batch(DDL)
        end
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, "failed to open #{path}: #{e.message}"
      end

      # Short retry for SQLITE_BUSY at INITIALIZATION (the WAL-switch race at
      # multi-process boot). ~10 attempts × 60ms ≈ 0.6s worst case — enough
      # for the winning process to finish the journal-mode switch. Only
      # here; the hot path uses `busy_timeout` + the in-process semaphore.
      def with_busy_retry(attempts: 10, backoff: 0.06)
        tries = 0
        begin
          yield
        rescue ::SQLite3::Exception => e
          raise unless e.message =~ /lock|busy/i

          tries += 1
          raise if tries >= attempts

          sleep(backoff)
          retry
        end
      end
      private :with_busy_retry

      # Rebuilds a WITHOUT ROWID kv (the old layout) into the rowid one. Checked
      # again under BEGIN IMMEDIATE: of N workers opening the file together only
      # the first rebuilds; the rest find it done. On a big file this takes
      # seconds, so a deployment should open the store once before its workers
      # (deploy/entrypoint.sh does).
      def rebuild_without_rowid!
        return unless without_rowid?

        @db.transaction(:immediate) do
          @db.execute_batch(REBUILD) if without_rowid?
        end
      end
      private :rebuild_without_rowid!

      def without_rowid?
        @db.get_first_value("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'kv'")
           .to_s.include?("WITHOUT ROWID")
      end
      private :without_rowid?

      def close
        @db&.close
        nil
      end

      def get(scope, key)
        row = @db.get_first_value(
          "SELECT value FROM kv WHERE scope = ? AND key = ?", [scope, key]
        )
        row.nil? ? nil : @serializer.parse(decode(row))
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      def set(scope, key, value)
        serialized = encode(serialize(value))       # fail-fast BEFORE writing
        group_write(scope, serialized.bytesize) do
          @db.execute(
            "INSERT OR REPLACE INTO kv (scope, key, value, updated_at) " \
            "VALUES (?, ?, ?, ?)",
            [scope, key, serialized, Time.now.utc.iso8601]
          )
        end
        value
      end

      # Many sets at once, riding the group commit like any other write: they join
      # the batch queued behind the lock instead of taking it once more.
      # entries: [[scope, key, value], ...] -> count written. Raises the first
      # failure, after every write has settled.
      def set_all(entries)
        # inside this fiber's own transaction: write there, never queue behind it
        return entries.each { |scope, key, value| set(scope, key, value) }.size if @tx_owner == Fiber.current

        writes = entries.map do |scope, key, value|
          serialized = encode(serialize(value))
          group_write_async(scope, serialized.bytesize) do
            @db.execute("INSERT OR REPLACE INTO kv (scope, key, value, updated_at) VALUES (?, ?, ?, ?)",
                        [scope, key, serialized, Time.now.utc.iso8601])
          end
        end
        flush_writes unless @flushing || writes.empty?
        errors = writes.filter_map do |promise|
          promise.wait
          nil
        rescue StandardError => e # a stopped leader too: the caller keeps the entries and retries
          e
        end
        raise errors.first if errors.any?

        writes.size
      end

      def delete(scope, key)
        group_write(scope, 0) do
          @db.execute("DELETE FROM kv WHERE scope = ? AND key = ?", [scope, key])
          @db.changes.positive?
        end
      end

      # A prefix is a primary-key RANGE [prefix, next): SQLite seeks straight to
      # it. Filtering the whole scope in Ruby read every row of it (values of tens
      # of KB in a WITHOUT ROWID table) while holding the GVL, so its cost grew with
      # the database and, called on every turn, starved the reactor.
      LIST_PREFIX_SQL = "SELECT key FROM kv WHERE scope = ? AND key >= ? AND key < ? ORDER BY key"

      def list(scope, prefix = nil)
        upper = prefix && range_end(prefix)
        return @db.execute(LIST_PREFIX_SQL, [scope, prefix, upper]).map(&:first) if upper

        keys = @db.execute("SELECT key FROM kv WHERE scope = ? ORDER BY key", [scope]).map(&:first)
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      # The smallest key above every key starting with `prefix`: its last byte + 1.
      # ASCII only (every prefix the stores use), so the bound stays valid UTF-8 and
      # compares byte-wise under BINARY; anything else falls back to the scan.
      def range_end(prefix)
        return nil if prefix.empty? || !prefix.ascii_only? || prefix.end_with?("\x7F")

        prefix[0...-1] + (prefix[-1].ord + 1).chr
      end
      private :range_end

      def scopes(prefix = nil)
        names = @db.execute("SELECT DISTINCT scope FROM kv ORDER BY scope").map(&:first)
        names = names.select { |s| s.start_with?(prefix) } if prefix
        names
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      # BEGIN IMMEDIATE ... COMMIT/ROLLBACK, serialized by the semaphore.
      # A nested one reuses the outer transaction.
      def transaction(&blk)
        return yield if @tx_owner == Fiber.current

        @write_semaphore.acquire do
          begin
            # N workers on one file: BEGIN IMMEDIATE can fail at once, with no
            # busy-handler wait, when this shared connection has a read open
            # (another fiber) and a sibling process just committed. Nothing is
            # written yet, so retrying the BEGIN alone is safe (~5s ceiling).
            with_busy_retry(attempts: 100, backoff: 0.05) { @db.transaction(:immediate) }
            @tx_owner = Fiber.current
            result = yield
            @db.commit
            result
          rescue StandardError
            @db.rollback if @db.transaction_active?
            raise
          ensure
            @tx_owner = nil
          end
        end
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      private

      # Values from this size up are stored deflated. Sessions and checkpoints carry
      # the whole transcript, and the WAL logs every write of one in full, so the
      # bytes each turn makes the database (and its replica) write shrink several
      # times for a fraction of a millisecond of CPU. A deflated value is a BLOB and
      # JSON is always text, so a read tells them apart without a marker, and rows
      # written before this stay readable as they are. Outside the store, a value
      # read straight from the table is inflated with any zlib (Zlib::Inflate.inflate).
      COMPRESS_FROM = 4096

      def encode(json)
        return json if json.bytesize < COMPRESS_FROM

        SQLite3::Blob.new(Zlib::Deflate.deflate(json, Zlib::BEST_SPEED))
      end

      def decode(row)
        row.encoding == Encoding::BINARY ? Zlib::Inflate.inflate(row).force_encoding(Encoding::UTF_8) : row
      end

      # Group commit for the single-statement writes (set/delete). The first one
      # becomes the leader and takes the write lock; every write that arrives while
      # it waits (on the semaphore, or on another PROCESS holding the file) joins
      # the same transaction and one COMMIT. Each caller still returns only after
      # its write is committed, so durability and per-fiber order are unchanged;
      # what drops is how often N workers fight over the file's one write lock.
      # A statement that fails fails only its own caller; one that leaves no
      # transaction behind (SQLite rolled it back) fails the whole batch. A leader
      # stopped before it committed hands the queue back: each write re-queues and
      # one of them leads.
      LeaderStopped = Class.new(StandardError)
      private_constant :LeaderStopped

      def group_write(scope, bytes, &op)
        return op.call if @tx_owner == Fiber.current # inside an explicit transaction

        begin
          write = [op, Async::Promise.new, scope, bytes]
          @pending_writes << write
          flush_writes unless @flushing
          write[1].wait
        rescue LeaderStopped
          retry
        end
      end

      # Queues a write without waiting for it. -> its promise
      def group_write_async(scope, bytes, &op)
        promise = Async::Promise.new
        @pending_writes << [op, promise, scope, bytes]
        promise
      end

      def flush_writes
        @flushing = true
        until @pending_writes.empty?
          batch = nil
          results = nil
          begin
            clock = [monotonic]
            transaction do
              clock << monotonic # the lock is ours
              batch = @pending_writes
              @pending_writes = []
              results = batch.map { |(op, _)| run_write(op) }
              raise Insika::StoreError, "the batch's transaction was rolled back" unless @db.transaction_active?

              clock << monotonic
            end
            clock << monotonic
            report_slow_batch(batch, clock) if @slow_ms
            batch.zip(results) { |(_, promise), (ok, value)| ok ? promise.resolve(value) : promise.reject(value) }
          rescue StandardError => e
            (batch || @pending_writes.slice!(0..)).each { |(_, promise)| promise.reject(e) unless promise.completed? }
          end
        end
      ensure
        @flushing = false
        # only non-empty when the leader stopped mid-flush (e.g. its task was cancelled)
        (Array(batch) + @pending_writes.slice!(0..)).each do |(_, promise)|
          promise.reject(LeaderStopped.new) unless promise.completed?
        end
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # One line per slow batch: wait = until the write lock was ours (this
      # process's semaphore and other processes holding the file), exec = the
      # statements, commit = COMMIT. A long wait with a short commit means
      # someone else holds the lock; a long commit means the batch itself is heavy.
      def report_slow_batch(batch, clock)
        start, locked, executed, committed = clock
        return if (committed - start) * 1000 < @slow_ms

        scopes = batch.map { |w| w[2].to_s.sub(/:.*/, ":*") }.tally.map { |name, n| "#{name}:#{n}" }.join(",")
        @slow_logger.warn(format("slow store batch writes=%d bytes=%d wait=%.1f ms exec=%.1f ms commit=%.1f ms scopes=%s",
                                 batch.size, batch.sum { |w| w[3] }, (locked - start) * 1000,
                                 (executed - locked) * 1000, (committed - executed) * 1000, scopes))
      end

      def run_write(op)
        [true, op.call]
      rescue ::SQLite3::Exception => e
        [false, Insika::StoreError.new(e.message)]
      end

      # Enforces the contract's type model at the boundary:
      # Symbol/symbol-key become String; a type outside the JSON model ->
      # StoreError on WRITE (fail-fast; never writes garbage).
      #
      # Does NOT use `generate(strict: true)`: under json 2.7.1 (the version that
      # ships with ruby 3.3.5 pinned in Gemfile.lock) `strict` REJECTS Symbol,
      # which would violate the Symbol coercion. The explicit validation
      # is independent of the json version and gives the SAME semantics as Memory.
      def serialize(value)
        ensure_jsonable!(value)
        @serializer.generate(value)
      rescue JSON::GeneratorError => e
        raise Insika::StoreError, "value not serializable: #{e.message}"
      end

      def ensure_jsonable!(value)
        case value
        when *JSONABLE then nil
        when Array then value.each { |v| ensure_jsonable!(v) }
        when Hash then value.each { |k, v| ensure_jsonable!(k); ensure_jsonable!(v) }
        else
          raise Insika::StoreError,
                "value not serializable: #{value.class} not allowed in JSON"
        end
      end
    end
  end
end
