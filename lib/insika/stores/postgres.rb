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
        )
      SQL

      # Serializes the DDL across processes booting together (CREATE TABLE IF NOT
      # EXISTS races on the catalog otherwise). Any constant works; this one spells "insika".
      DDL_LOCK = 0x696e73696b61

      UPSERT = "INSERT INTO insika_kv (scope, key, value, updated_at) VALUES ($1, $2, $3, now()) " \
               "ON CONFLICT (scope, key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at"

      GET = "SELECT value FROM insika_kv WHERE scope = $1 AND key = $2"

      # Inside a transaction a read first takes the key's advisory lock (held to
      # COMMIT/ROLLBACK), in its OWN statement: under READ COMMITTED a statement
      # reads the snapshot it started with, so a SELECT that waited on the lock
      # would still see the value from before the holder committed. The read that
      # follows starts after the lock is ours and sees the committed value.
      KEY_LOCK = "SELECT pg_advisory_xact_lock(hashtextextended($1 || ' ' || $2, 0))"

      # pool: connections this process may open (lazily, on first use).
      def initialize(url:, pool: 5)
        require "pg" # lazy: the core installs without libpq
        @url = url
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
        with_conn { |c| c.exec_params(UPSERT, [scope, key, serialized]) }
        value
      end

      def delete(scope, key)
        with_conn do |c|
          c.exec_params("DELETE FROM insika_kv WHERE scope = $1 AND key = $2", [scope, key]).cmd_tuples.positive?
        end
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
      def transaction
        return yield if @tx[Fiber.current]

        conn = checkout
        begin
          conn.exec("BEGIN")
          @tx[Fiber.current] = conn
          result = yield
          conn.exec("COMMIT")
          result
        rescue Exception # roll back on anything (a stopped fiber too), then re-raise it
          begin
            conn.exec("ROLLBACK") if conn.status == PG::CONNECTION_OK && conn.transaction_status != PG::PQTRANS_IDLE
          rescue PG::Error
            nil # a dead connection was rolled back by the server; keep the original error
          end
          raise
        ensure
          @tx.delete(Fiber.current)
          checkin(conn)
        end
      rescue PG::Error => e
        raise Insika::StoreError, e.message
      end

      def close
        until @pool.empty?
          conn = @pool.pop(true)
          conn&.close
        end
        nil
      end

      private

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

      def checkout = @pool.pop || connect

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

      def connect = PG.connect(@url)

      # Its own short-lived connection, closed before returning: a server forks
      # its workers after the app is built, and an inherited socket would be
      # shared by every child.
      def migrate
        conn = connect
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
