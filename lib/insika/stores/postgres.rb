# frozen_string_literal: true

module Insika
  module Stores
    # Postgres backend — opt-in (INSIKA_DATABASE_URL). Same single kv shape as
    # SQLite: one table, the domain lives in the scopes. Unlike SQLite there is no
    # file-wide write lock: concurrent writers only meet on the keys they share,
    # which is what lets N worker processes write without queueing behind each other.
    #
    # Values stay JSON text (not jsonb): what was written is what is read, byte for
    # byte, and the server never parses them. COLLATE "C" makes list/scopes sort
    # byte-wise, like Ruby's sort and SQLite's BINARY.
    class Postgres
      include Store
      include JsonValue

      DDL = <<~SQL
        CREATE TABLE IF NOT EXISTS insika_kv (
          scope      text COLLATE "C" NOT NULL,
          key        text COLLATE "C" NOT NULL,
          value      text NOT NULL,
          updated_at timestamptz NOT NULL DEFAULT now(),
          PRIMARY KEY (scope, key)
        );
        CREATE INDEX IF NOT EXISTS insika_kv_recent ON insika_kv (scope, updated_at DESC)
      SQL

      # Serializes the DDL across processes booting together (CREATE TABLE IF NOT
      # EXISTS races on the catalog otherwise). Any constant works; this one spells "insika".
      DDL_LOCK = 0x696e73696b61

      GET = "SELECT value FROM insika_kv WHERE scope = $1 AND key = $2"

      # Inside a transaction a read first takes the key's advisory lock (held to
      # COMMIT/ROLLBACK), in its OWN statement: under READ COMMITTED a statement
      # reads the snapshot it started with, so a SELECT that waited on the lock
      # would still see the value from before the holder committed. The read that
      # follows starts after the lock is ours and sees the committed value.
      KEY_LOCK = "SELECT pg_advisory_xact_lock(hashtextextended($1 || ' ' || $2, 0))"

      # Outside a transaction a write takes the same key lock in its own statement,
      # so it waits for any transaction that read the key, as SQLite queued every
      # write behind an open transaction. Released when the statement ends.
      LOCKED_UPSERT = "WITH l AS (SELECT pg_advisory_xact_lock(hashtextextended($1 || ' ' || $2, 0))) " \
                      "INSERT INTO insika_kv (scope, key, value, updated_at) SELECT $1, $2, $3, clock_timestamp() FROM l " \
                      "ON CONFLICT (scope, key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at"
      LOCKED_DELETE = "WITH l AS (SELECT pg_advisory_xact_lock(hashtextextended($1 || ' ' || $2, 0))) " \
                      "DELETE FROM insika_kv WHERE scope = $1 AND key = $2 AND EXISTS (SELECT 1 FROM l)"

      # A transaction the server aborted as a deadlock is run again: it was rolled
      # back whole, so re-running is SQLite's wait-then-run. Blocks only touch the
      # store (side effects happen after the commit), so a re-run is safe.
      DEADLOCK_ATTEMPTS = 3

      # Waits on a lock or a connect give up like SQLite's busy timeout did.
      CONNECT_OPTIONS = { connect_timeout: 5, options: "-c lock_timeout=5000" }.freeze

      # pool: connections this process may open (lazily, on first use). A
      # transaction holds its connection across several round trips while its
      # fiber yields to others, so under many concurrent turns a small pool is
      # where calls queue.
      def initialize(url:, pool: 10)
        require "pg" # lazy: the core installs without libpq
        raise ArgumentError, "pool must be at least 1 (got #{pool.inspect})" unless pool.is_a?(Integer) && pool >= 1

        @url = url
        @closed = false
        @pool = Thread::Queue.new
        pool.times { @pool << nil } # nil = a slot not connected yet
        @tx = {}                    # Fiber => connection pinned to its open transaction
        migrate
      end

      def get(scope, key)
        row = with_conn do |c|
          c.exec_params(KEY_LOCK, [scope, key]) if @tx[Fiber.current]
          c.exec_params(GET, [scope, key]).first
        end
        row && JSON.parse(row["value"])
      end

      def set(scope, key, value)
        serialized = serialize(value) # fail-fast BEFORE writing
        # One statement in or out of a transaction: the key lock and the write
        # together (inside a transaction the lock is still held to COMMIT).
        with_conn { |c| c.exec_params(LOCKED_UPSERT, [scope, key, serialized]) }
        value
      end

      def delete(scope, key)
        with_conn { |c| c.exec_params(LOCKED_DELETE, [scope, key]).cmd_tuples.positive? }
      end

      # A prefix is a start_with? on the key, never a LIKE pattern (no escaping of
      # % or _ to get wrong). An ASCII prefix is a primary-key RANGE [prefix, next):
      # an index seek, like SQLite's (the stores list key prefixes on every turn).
      # Anything else compares left(key, n): still exact, scanned within the scope.
      def list(scope, prefix = nil)
        upper = prefix && range_end(prefix)
        rows = with_conn do |c|
          if upper
            c.exec_params("SELECT key FROM insika_kv WHERE scope = $1 AND key >= $2 AND key < $3 ORDER BY key",
                          [scope, prefix, upper])
          elsif prefix
            c.exec_params("SELECT key FROM insika_kv WHERE scope = $1 AND left(key, length($2)) = $2 ORDER BY key",
                          [scope, prefix])
          else
            c.exec_params("SELECT key FROM insika_kv WHERE scope = $1 ORDER BY key", [scope])
          end
        end
        rows.map { |r| r["key"] }
      end

      # One query for the pairs (see Store#entries): one round trip instead of one
      # per key. No lock, like #list.
      def entries(scope, prefix = nil)
        upper = prefix && range_end(prefix)
        rows = with_conn do |c|
          if upper
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 AND key >= $2 AND key < $3 ORDER BY key",
                          [scope, prefix, upper])
          elsif prefix
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 AND left(key, length($2)) = $2 ORDER BY key",
                          [scope, prefix])
          else
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 ORDER BY key", [scope])
          end
        end
        rows.map { |r| [r["key"], JSON.parse(r["value"])] }
      end

      # Newest first by the write time (updated_at, indexed with the scope); key
      # breaks a tie. Only the top `limit` values travel.
      def recent(scope, prefix, limit)
        upper = prefix && range_end(prefix)
        rows = with_conn do |c|
          if upper
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 AND key >= $2 AND key < $3 " \
                          "ORDER BY updated_at DESC, key DESC LIMIT $4", [scope, prefix, upper, limit])
          elsif prefix
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 AND left(key, length($2)) = $2 " \
                          "ORDER BY updated_at DESC, key DESC LIMIT $3", [scope, prefix, limit])
          else
            c.exec_params("SELECT key, value FROM insika_kv WHERE scope = $1 ORDER BY updated_at DESC, key DESC LIMIT $2",
                          [scope, limit])
          end
        end
        rows.map { |r| [r["key"], JSON.parse(r["value"])] }
      end

      def scopes(prefix = nil)
        names = with_conn { |c| c.exec("SELECT DISTINCT scope FROM insika_kv ORDER BY scope") }.map { |r| r["scope"] }
        prefix ? names.select { |s| s.start_with?(prefix) } : names
      end

      # Read-check-write is atomic: every key READ inside the transaction is locked
      # first (see KEY_LOCK), so a second transaction reading the same key waits —
      # the role BEGIN IMMEDIATE plays on SQLite, but per key instead of per file.
      # It covers keys that do not exist yet, which a row lock cannot. Different
      # keys never wait on each other; a hash collision only over-serializes.
      # A nested transaction reuses the outer one.
      def transaction(&blk)
        return yield if @tx[Fiber.current]

        attempts = 0
        begin
          attempts += 1
          run_transaction(&blk)
        rescue PG::TRDeadlockDetected, Insika::StoreError => e
          deadlock = e.is_a?(PG::TRDeadlockDetected) || e.cause.is_a?(PG::TRDeadlockDetected)
          retry if deadlock && attempts < DEADLOCK_ATTEMPTS
          raise
        end
      rescue PG::Error => e
        raise Insika::StoreError, e.message
      end

      # Closes the idle connections; a call after close raises instead of waiting.
      def close
        @closed = true
        until @pool.empty?
          conn = @pool.pop(true)
          conn&.close
        end
        nil
      end

      private

      # One attempt: BEGIN, the block, COMMIT. Anything that leaves without the
      # COMMIT — an exception, a stopped fiber, or a `return`/`break` out of the
      # block — rolls back, so a connection never goes back to the pool inside an
      # open transaction (holding its key locks).
      def run_transaction
        conn = checkout
        committed = false
        begin
          conn.exec("BEGIN")
          @tx[Fiber.current] = conn
          result = yield
          conn.exec("COMMIT")
          committed = true
          result
        ensure
          @tx.delete(Fiber.current)
          rollback(conn) unless committed
          checkin(conn)
        end
      end

      def rollback(conn)
        conn.exec("ROLLBACK") if conn.status == PG::CONNECTION_OK && conn.transaction_status != PG::PQTRANS_IDLE
      rescue PG::Error
        nil # a dead connection was rolled back by the server; keep the original error
      end

      # The smallest key above every key starting with `prefix` (last byte + 1).
      # ASCII only, so the bound stays valid text and compares byte-wise under "C".
      def range_end(prefix)
        return nil if prefix.empty? || !prefix.ascii_only? || prefix.end_with?("\x7F")

        prefix[0...-1] + (prefix[-1].ord + 1).chr
      end

      # A connection for one call: the fiber's pinned one inside a transaction,
      # otherwise one borrowed from the pool and returned after. Thread::Queue#pop
      # parks only the calling fiber under a fiber scheduler.
      def with_conn
        pinned = @tx[Fiber.current]
        return yield(pinned) if pinned

        conn = checkout
        begin
          yield conn
        ensure
          checkin(conn)
        end
      rescue PG::Error => e
        raise Insika::StoreError, e.message
      end

      # A borrower whose connect fails gives the empty slot back: otherwise every
      # failed reconnect during an outage would shrink the pool until calls wait
      # forever.
      def checkout
        raise Insika::StoreError, "store closed" if @closed

        @pool.pop || begin
          connect
        rescue StandardError
          @pool << nil
          raise
        end
      end

      # A connection the server dropped is not returned: its slot comes back empty
      # and the next borrower connects afresh.
      def checkin(conn)
        if conn && conn.status == PG::CONNECTION_OK
          @pool << conn
        else
          conn&.close
          @pool << nil
        end
      end

      def connect = PG.connect(@url, **CONNECT_OPTIONS)

      # Its own short-lived connection, closed before returning: a server forks
      # its workers after the app is built, and an inherited socket would be
      # shared by every child.
      def migrate
        conn = connect
        conn.exec("SET client_min_messages TO warning") # no "already exists, skipping" on every boot
        conn.transaction do
          conn.exec_params("SELECT pg_advisory_xact_lock($1)", [DDL_LOCK])
          conn.exec(DDL)
        end
      rescue PG::Error => e
        raise Insika::StoreError, "failed to prepare insika_kv: #{e.message}"
      ensure
        conn&.close
      end
    end
  end
end
