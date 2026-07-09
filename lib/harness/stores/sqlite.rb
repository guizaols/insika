# frozen_string_literal: true

require "json"
require "time"
require "async/semaphore"

module Harness
  module Stores
    # Backend SQLite — default de produção (doc 01 §3, RFC-0006 §3).
    # Tabela única kv (L1); domínio vive nos scopes. Um handle por processo,
    # escritas em transação serializadas por Async::Semaphore (doc 01 §5).
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

      # Tipos do modelo JSON + Symbol (coerido a String na escrita, C8).
      # Qualquer outro tipo é "lixo" e deve ser rejeitado (C22). Idêntico ao
      # Stores::Memory — os dois backends compartilham o MESMO modelo de tipos
      # (L2: a suíte de contrato é honesta).
      JSONABLE = [NilClass, TrueClass, FalseClass, Integer, Float,
                  String, Symbol].freeze
      private_constant :JSONABLE

      # require lazy (doc 01 §8): o núcleo instala sem a gem sqlite3
      # quando só o Memory é usado.
      def initialize(path:, serializer: JSON)
        require "sqlite3"

        @serializer = serializer
        @db = SQLite3::Database.new(path)
        @write_semaphore = Async::Semaphore.new(1)
        @tx_owner = nil

        @db.execute("PRAGMA journal_mode = WAL")   # RFC-0006 §6
        @db.execute("PRAGMA synchronous = NORMAL")
        @db.busy_timeout = 5_000                   # L6 — rede de segurança
        @db.execute_batch(DDL)
        @db.execute(
          "CREATE INDEX IF NOT EXISTS kv_scope_prefix ON kv (scope, key)"
        )
      rescue ::SQLite3::Exception => e
        raise Harness::StoreError, "falha ao abrir #{path}: #{e.message}"
      end

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
        raise Harness::StoreError, e.message
      end

      def set(scope, key, value)
        serialized = serialize(value)               # fail-fast ANTES de gravar
        write do
          @db.execute(
            "INSERT OR REPLACE INTO kv (scope, key, value, updated_at) " \
            "VALUES (?, ?, ?, ?)",
            [scope, key, serialized, Time.now.utc.iso8601]
          )
        end
        value
      end

      def delete(scope, key)
        write do
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
        raise Harness::StoreError, e.message
      end

      # BEGIN IMMEDIATE ... COMMIT/ROLLBACK, serializado pelo semáforo
      # (doc 01 §5). Aninhada reusa a transação externa (doc 01 §2).
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
        raise Harness::StoreError, e.message
      end

      private

      # Toda escrita individual passa por transaction — assim TODAS as
      # escritas serializam no semáforo (doc 01 §5) e set/delete dentro de
      # uma transação externa participam dela (reuso por aninhamento).
      def write(&blk)
        transaction(&blk)
      end

      # Enforce o modelo de tipos do contrato na borda (doc 01 §2, §6):
      # Symbol/símbolo-chave viram String (C8); tipo fora do modelo JSON ->
      # StoreError na ESCRITA (fail-fast; nunca grava lixo — C22).
      #
      # NÃO usa `generate(strict: true)`: sob json 2.7.1 (a versão que vem com
      # o ruby 3.3.5 travado no Gemfile.lock) `strict` REJEITA Symbol, o que
      # violaria C8 — foi o alerta deixado pela task 3. A validação explícita
      # é independente da versão do json e dá a MESMA semântica do Memory (L2).
      def serialize(value)
        ensure_jsonable!(value)
        @serializer.generate(value)
      rescue JSON::GeneratorError => e
        raise Harness::StoreError, "valor não serializável: #{e.message}"
      end

      def ensure_jsonable!(value)
        case value
        when *JSONABLE then nil
        when Array then value.each { |v| ensure_jsonable!(v) }
        when Hash then value.each { |k, v| ensure_jsonable!(k); ensure_jsonable!(v) }
        else
          raise Harness::StoreError,
                "valor não serializável: #{value.class} not allowed in JSON"
        end
      end
    end
  end
end
