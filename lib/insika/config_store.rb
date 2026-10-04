# frozen_string_literal: true

require "json"
require "securerandom"
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

    # Rewritten on every config write. A cache sees another process's write by
    # finding a different token. Outside SCOPES, so no authored scope lists it.
    VERSION_SCOPE = "#{SCOPE_PREFIX}:_version"
    VERSION_KEY = "token"
    # The server's recheck window (seconds): how stale another worker's write may
    # be seen. Embedders keep 0 (no cache) unless they opt in.
    RECHECK = 1.0

    # recheck: 0 = no cache, every read goes to the store (the default).
    # recheck > 0 = reads are served from memory; the version token is re-read
    # at most once per `recheck` seconds and a changed token drops the cache.
    def initialize(store:, recheck: 0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @store = store
      @recheck = recheck
      @clock = clock
      @cache = {}
      @token = nil
      @checked_at = nil
      @lock = Mutex.new
    end

    attr_reader :recheck

    # Upsert (last-write-wins). -> value (the same Hash that was passed)
    def put(scope, key, value)
      s = ns(scope)
      @store.transaction do
        @store.set(s, key.to_s, stringify(value))
        bump_version
      end
      forget
      value
    end

    # -> Hash | nil
    def get(scope, key)
      s = ns(scope)
      cached([:get, s, key.to_s]) { @store.get(s, key.to_s) }
    end

    # -> bool (did it exist?)
    def delete(scope, key)
      s = ns(scope)
      existed = @store.transaction do
        @store.delete(s, key.to_s).tap { |gone| bump_version if gone }
      end
      forget
      existed
    end

    # -> [String] keys of the scope, sorted lexicographically
    def keys(scope)
      s = ns(scope)
      cached([:keys, s]) { @store.list(s) }
    end

    # -> [Hash] all records of the scope (lexicographic key order), one store call
    def all(scope)
      s = ns(scope)
      cached([:all, s]) { @store.entries(s).map(&:last) }
    end

    private

    # The cache keeps JSON text, not objects: every hit parses a fresh copy, so a
    # caller that mutates what it got never changes what the next caller reads.
    def cached(entry)
      return yield unless @recheck.positive?

      revalidate
      raw = @lock.synchronize { @cache[entry] }
      return JSON.parse(raw) if raw

      value = yield
      @lock.synchronize { @cache[entry] = JSON.generate(value) }
      value
    end

    def revalidate
      now = @clock.call
      return if @checked_at && now - @checked_at < @recheck

      token = @store.get(VERSION_SCOPE, VERSION_KEY)
      @lock.synchronize do
        @cache.clear unless token == @token
        @token = token
        @checked_at = now
      end
    end

    def bump_version = @store.set(VERSION_SCOPE, VERSION_KEY, SecureRandom.hex(8))

    # Our own write: drop everything and re-read the token on the next read.
    def forget = @lock.synchronize { @cache.clear; @checked_at = nil }

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
