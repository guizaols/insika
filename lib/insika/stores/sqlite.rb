# frozen_string_literal: true

require "json"
require "time"
require "async/semaphore"

module Insika
  module Stores
    # SQLite backend — the production default.
    # A single kv table; the domain lives in the scopes. One handle per process,
    # writes in a transaction serialized by an Async::Semaphore.
    class SQLite
      include Store

      DDL = <<~SQL
        CREATE TABLE IF NOT EXISTS kv (
          scope      TEXT    NOT NULL,
          key        TEXT    NOT NULL,
          value      TEXT    NOT NULL,
          updated_at TEXT    NOT NULL,
          PRIMARY KEY (scope, key)
        ) WITHOUT ROWID;
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
      def initialize(path:, serializer: JSON)
        require "sqlite3"

        @serializer = serializer
        @db = SQLite3::Database.new(path)
        @write_semaphore = Async::Semaphore.new(1)
        @tx_owner = nil

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
          @db.execute_batch(DDL)
        end
        # The WITHOUT ROWID PRIMARY KEY (scope, key) is already the prefix index —
        # there is no extra index to create.
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

      def close
        @db&.close
        nil
      end

      def get(scope, key)
        row = @db.get_first_value(
          "SELECT value FROM kv WHERE scope = ? AND key = ?", [scope, key]
        )
        row.nil? ? nil : @serializer.parse(row)
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      def set(scope, key, value)
        serialized = serialize(value)               # fail-fast BEFORE writing
        transaction do
          @db.execute(
            "INSERT OR REPLACE INTO kv (scope, key, value, updated_at) " \
            "VALUES (?, ?, ?, ?)",
            [scope, key, serialized, Time.now.utc.iso8601]
          )
        end
        value
      end

      def delete(scope, key)
        transaction do
          @db.execute("DELETE FROM kv WHERE scope = ? AND key = ?", [scope, key])
          @db.changes.positive?
        end
      end

      def list(scope, prefix = nil)
        keys = @db.execute(
          "SELECT key FROM kv WHERE scope = ? ORDER BY key", [scope]
        ).map(&:first)
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      rescue ::SQLite3::Exception => e
        raise Insika::StoreError, e.message
      end

      # BEGIN IMMEDIATE ... COMMIT/ROLLBACK, serialized by the semaphore.
      # A nested one reuses the outer transaction.
      def transaction(&blk)
        return yield if @tx_owner == Fiber.current

        @write_semaphore.acquire do
          begin
            @db.transaction(:immediate)
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
