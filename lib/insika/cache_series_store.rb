# frozen_string_literal: true

module Insika
  #   — per-AGENT cache-hit series (scope "cache_series"), for the
  # Studio agent-detail plot. Sessions do not stamp their agent, so the
  # per-session context trace cannot answer "cache-hit over time for THIS
  # agent"; this capped list can. Entries are counts and a category name only —
  # PII-free by construction. No retention hook: the cap bounds growth.
  class CacheSeriesStore
    SCOPE = "cache_series"
    MAX_PER_AGENT = 200 # oldest dropped; one entry per turn, so 200 is a
    # rolling window, not a leak path

    def initialize(store:)
      @store = store
    end

    # Appends a sanitized entry for the agent; caps. Rescues everything — the
    # series never breaks the turn.
    def record(agent:, entry:)
      return if agent.to_s.empty?

      list = (@store.get(SCOPE, agent.to_s) || []) + [sanitize(entry)]
      @store.set(SCOPE, agent.to_s, list.last(MAX_PER_AGENT))
    rescue StandardError
      nil
    end

    # -> [Hash] the agent's series, chronological. [] if none.
    def for_agent(agent) = @store.get(SCOPE, agent.to_s) || []

    private

    def sanitize(entry)
      e = entry.is_a?(Hash) ? entry : {}
      {
        "at" => (e[:at] || e["at"])&.to_s,
        "turn" => int(e[:turn] || e["turn"]),
        "hit_pct" => int_or_nil(e[:hit_pct] || e["hit_pct"]),
        "cached_tokens" => int(e[:cached_tokens] || e["cached_tokens"]),
        "prompt_tokens" => int(e[:prompt_tokens] || e["prompt_tokens"]),
        "invalidation_reason" => (e[:invalidation_reason] || e["invalidation_reason"])&.to_s
      }
    end

    def int(value) = Integer(value || 0)
    def int_or_nil(value) = value.nil? ? nil : Integer(value)
  end
end
