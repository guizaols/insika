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
      include JsonValue

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

      # Re-inserted on every write, so the Hash's order is the write order (#recent).
      def set(scope, key, value)
        raw = serialize(value)
        @data[scope].delete(key)
        @data[scope][key] = raw
        value
      end

      def delete(scope, key)
        !@data[scope].delete(key).nil?
      end

      def list(scope, prefix = nil)
        keys = @data[scope].keys.sort
        prefix ? keys.select { |k| k.start_with?(prefix) } : keys
      end

      def recent(scope, prefix, limit, offset = 0)
        @data[scope].reverse_each.lazy
                    .select { |key, _| prefix.nil? || key.start_with?(prefix) }
                    .drop(offset).first(limit).map { |key, raw| [key, JSON.parse(raw)] }
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

      private

      def new_store
        Hash.new { |h, scope| h[scope] = {} }
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
  
    # Survives a restart? Every backend except Memory does.
    def self.durable?(backend) = !backend.is_a?(Memory)
end
end
