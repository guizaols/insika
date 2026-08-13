# frozen_string_literal: true

require "json"

module Insika
  module Stores
    # In-memory backend for dev/test.
    # Serializes JSON even in memory: exact parity of type semantics
    # with SQLite — the contract suite is honest.
    # No lock: cooperative fibers do not preempt in the middle of a Hash
    # operation.
    class Memory
      include Store

      def initialize
        @data = new_store
        @tx_depth = 0
        @snapshot = nil
      end

      def get(scope, key)
        raw = @data[scope][key]
        return nil if raw.nil?

        JSON.parse(raw)
      end

      def set(scope, key, value)
        @data[scope][key] = serialize(value)
        value
      end

      def delete(scope, key)
        !@data[scope].delete(key).nil?
      end

      def list(scope, prefix = nil)
        keys = @data[scope].keys.sort
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      end

      def scopes(prefix = nil)
        names = @data.keys
        names = names.select { |s| s.start_with?(prefix) } if prefix
        names.sort
      end

      # Snapshot at the start of the outermost transaction; an exception at any
      # level -> restore the snapshot and re-propagate (a REAL rollback).
      # A nested one reuses the outer (no SAVEPOINT).
      def transaction
        if @tx_depth.positive?
          @tx_depth += 1
          begin
            return yield
          ensure
            @tx_depth -= 1
          end
        end

        @snapshot = deep_snapshot
        @tx_depth = 1
        begin
          yield
        rescue StandardError
          restore_snapshot
          raise
        ensure
          @tx_depth = 0
          @snapshot = nil
        end
      end

      # JSON model types + Symbol (coerced to String on write).
      # Any other type is "garbage" and must be rejected.
      JSONABLE = [NilClass, TrueClass, FalseClass, Integer, Float,
                  String, Symbol].freeze
      private_constant :JSONABLE

      private

      def new_store
        Hash.new { |h, scope| h[scope] = {} }
      end

      # Enforces the contract's type model at the boundary:
      # Symbol/symbol-key become String; a type outside the JSON model ->
      # StoreError on WRITE (fail-fast; never writes garbage).
      #
      # Does not use `JSON.generate(strict: true)`: under json 2.7.1 (the pinned
      # version) `strict` rejects Symbol, which would violate the Symbol coercion.
      # The explicit validation is independent of the json version and gives the
      # SAME semantics as SQLite.
      # The transaction block's exception (from the caller) propagates without
      # wrapping; only a backend error becomes StoreError.
      def serialize(value)
        ensure_jsonable!(value)
        JSON.generate(value)
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

      # Deep dup: the values are already JSON strings (immutable in practice),
      # so a per-scope dup is enough — there is no nested mutable structure.
      def deep_snapshot
        @data.each_with_object({}) { |(scope, kv), acc| acc[scope] = kv.dup }
      end

      # Recreates the Hash with the default proc (otherwise @data[scope] on a
      # new scope after rollback would raise) and restores only the snapshot's
      # scopes — scopes created inside the transaction disappear.
      def restore_snapshot
        @data = new_store
        @snapshot.each { |scope, kv| @data[scope] = kv }
      end
    end
  end
end
