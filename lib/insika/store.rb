# frozen_string_literal: true

module Insika
  # Minimal persistence contract.
  # Namespace-scoped KV, transactional when the backend supports it.
  # Every implementation passes the SAME contract suite
  # (lib/insika/testing/store_contract.rb — requirable from outside the repo,
  # Values must be JSON-serializable.
  #
  # scope: String — separates domains/tenants (e.g. "sessions", "tasks:tenant_x")
  # key:   Hierarchical String (e.g. "task:123", "checkpoint:123:turn:4")
  #
  # Contract rules (verified by the suite):
  # - get on a nonexistent key -> nil (never an exception)
  # - set overwrites silently (last-write-wins)
  # - round-trip preserves JSON types; Symbols become Strings (the domain
  #   normalizes at the boundary)
  # - list(scope) returns only keys of the scope, ordered lexicographically;
  #   prefix filters by start_with?
  # - a nested transaction reuses the outer transaction (no SAVEPOINT)
  # - a serialization failure on write -> Insika::StoreError (fail-fast)
  #
  # Backends `include Store` and override the five methods; any forgotten
  # method raises NotImplementedError (fail-fast, better than a distant
  # NoMethodError).
  module Store
    # -> Object | nil (deserialized)
    def get(scope, key)
      raise NotImplementedError, "#{self.class}#get"
    end

    # -> value (the SAME object passed in, not the round-trip)
    def set(scope, key, value)
      raise NotImplementedError, "#{self.class}#set"
    end

    # -> true | false (did it exist?)
    def delete(scope, key)
      raise NotImplementedError, "#{self.class}#delete"
    end

    # -> [String] keys ordered lexicographically
    def list(scope, prefix = nil)
      raise NotImplementedError, "#{self.class}#list"
    end

    # -> the block's result; atomic if the backend supports it
    def transaction(&blk)
      raise NotImplementedError, "#{self.class}#transaction"
    end
  end
end
