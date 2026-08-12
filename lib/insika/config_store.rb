# frozen_string_literal: true

require "time"

module Insika
  # CONFIGURATION DOMAIN store. Unlike the
  # EXECUTION stores (session/task/checkpoint/pending/memory), this holds the
  # configuration the Studio authors at runtime: agents (profiles), general
  # settings, LLM providers and MCP instances. Scoped KV over any
  # `Insika::Store` — durable when the backend is SQLite (survives a restart,
  # like everything else).
  #
  # logical scope -> physical namespace "config:<scope>". Values are
  # JSON-serializable Hashes (symbol becomes string on the round-trip, per the
  # Store contract; the domain re-symbolizes at the edge — see StoredProfileSource).
  class ConfigStore
    SCOPE_PREFIX = "config"
    # agent_files/skills: the CONTENT of per-agent prompts
    # and shared skills lives in the Store (single source of truth,
    # a SQLite backup), not on disk — disk becomes only seed/import.
    # goldens: authored eval cases — config, like the
    # prompts and skills: the corpus on disk is seed and export, the store is what a
    # deployment runs and what the Studio edits.
    # baselines: the ACCEPTED state of each agent's golden set.
    # Config for the same reason: it is a curated decision ("this is the bar"), the
    # file is its export, and the refinement gate reads it from inside a deployment
    # that has no checkout.
    # agent_skills: the per-agent SPECIALIZATIONS of a shared skill (and
    # agent-private skills). A second scope rather than a composite key in `skills`,
    # so the shared records are untouched by the agent dimension arriving — no
    # migration, and a live deployment keeps serving exactly what it served.
    SCOPES = %w[agents settings llm_providers mcp agent_files skills agent_skills
                system_files tools goldens baselines].freeze

    class UnknownScope < Insika::Error; end

    def initialize(store:)
      @store = store
    end

    # Upsert (last-write-wins). -> value (the same Hash that was passed)
    def put(scope, key, value)
      @store.set(ns(scope), key.to_s, stringify(value))
      value
    end

    # -> Hash | nil
    def get(scope, key)
      @store.get(ns(scope), key.to_s)
    end

    # -> bool (did it exist?)
    def delete(scope, key)
      @store.delete(ns(scope), key.to_s)
    end

    # -> [String] keys of the scope, sorted lexicographically
    def keys(scope)
      @store.list(ns(scope))
    end

    # -> [Hash] all records of the scope (lexicographic key order)
    def all(scope)
      s = ns(scope)
      @store.list(s).filter_map { |k| @store.get(s, k) }
    end

    private

    def ns(scope)
      key = scope.to_s
      raise UnknownScope, "unknown config scope: #{scope.inspect}" unless SCOPES.include?(key)

      "#{SCOPE_PREFIX}:#{key}"
    end

    # Normalizes symbol->string BEFORE writing (mirrors MemoryStore#stringify):
    # the backend serializes JSON, and reading back would return strings anyway;
    # normalizing on write keeps the record consistent across backends.
    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = stringify(v) }
      when Array then obj.map { |v| stringify(v) }
      when Symbol then obj.to_s
      else obj
      end
    end
  end
end
