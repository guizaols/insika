# frozen_string_literal: true

module Insika
  # Per-session CONTEXT trace, for the Studio's breakdown-by-category card
  # One record per session in the raw backend (scope
  # "context_traces") — RUNTIME data, next to sessions/tasks, like the
  # ToolTraceStore it mirrors. A capped LIST of entries, ONE PER TURN, written
  # by the Executor after tool assembly.
  #
  # Unlike the tool trace there is NO security machinery here by construction:
  # the entry is counts and provider ids only (category -> tokens/fragments/
  # pinned, the tools estimate, the budget verdict) — never fragment content,
  # so there is nothing to mask. `record` still rescues everything: the trace
  # NEVER breaks the turn.
  class ContextTraceStore
    SCOPE = "context_traces"
    MAX_PER_SESSION = 50 # one per turn; turns are the unit, not tool calls

    def initialize(store:)
      @store = store
    end

    # Writes an entry into the session — UPSERT by (task_id, turn): a turn that
    # suspends (approval) and resumes re-runs the context stage, and the
    # re-record replaces the first one instead of duplicating it. (`turn` is
    # 1-based PER TASK, so the task is part of the key.) Missing session_id ->
    # no-op. -> the sanitized entry (RFC-0030 C5 parks it on TurnState for the
    # stage-8 cache merge).
    def record(session_id:, entry:)
      sid = session_id.to_s
      return if sid.empty?

      e = sanitize(entry)
      key = [e["task_id"], e["turn"]]
      list = (@store.get(SCOPE, sid) || []).reject { |x| [x["task_id"], x["turn"]] == key } + [e]
      @store.set(SCOPE, sid, list.last(MAX_PER_SESSION))
      e
    rescue StandardError
      nil
    end

    # -> [Hash] session entries in chronological order. [] if none.
    def for_session(session_id) = @store.get(SCOPE, session_id.to_s) || []

    # Discards a session's trace (cleanup). -> bool (did it exist?).
    def clear(session_id) = @store.delete(SCOPE, session_id.to_s)

    private

    # Keeps only the known shape; coerces numbers and strings so a caller bug
    # degrades the card instead of poisoning the record.
    def sanitize(entry)
      e = entry.is_a?(Hash) ? entry : {}
      categories = e[:categories] || e["categories"] || {}
      tools = e[:tools] || e["tools"] || {}
      {
        "task_id" => (e[:task_id] || e["task_id"]).to_s,
        "turn" => int(e[:turn] || e["turn"]),
        "at" => (e[:at] || e["at"]).to_s,
        "cap" => int(e[:cap] || e["cap"]),
        "used" => int(e[:used] || e["used"]),
        "evicted" => Array(e[:evicted] || e["evicted"]).map(&:to_s),
        "categories" => categories.each_with_object({}) do |(name, c), acc|
          c = {} unless c.is_a?(Hash)
          cat = { "tokens" => int(c[:tokens] || c["tokens"]),
                  "fragments" => int(c[:fragments] || c["fragments"]),
                  "pinned" => int(c[:pinned] || c["pinned"]) }
          # RFC-0030 C4: which cache layer the category belongs to ("identity" |
          # "volatile"). Absent for a category recorded before the contract (or
          # one that never learned it) — the view guards on nil.
          layer = c[:layer] || c["layer"]
          cat["layer"] = layer.to_s if layer
          # WHAT the category carried and WHY ({name, reason}) — still ids only, so
          # the no-masking-needed contract above holds. Omitted when empty: most
          # categories have nothing to name and an empty key is just noise.
          labels = normalize_labels(c[:labels] || c["labels"])
          cat["labels"] = labels unless labels.empty?
          acc[name.to_s] = cat
        end,
        "tools" => { "count" => int(tools[:count] || tools["count"]),
                     "tokens" => int(tools[:tokens] || tools["tokens"]) },
        "fingerprints" => fingerprints_of(e[:fingerprints] || e["fingerprints"]),
        "cache" => cache_of(e[:cache] || e["cache"])
      }.compact
    end

    # RFC-0030 C4: { name => sha256-hex }; names stringified, non-strings
    # dropped. Absent when the caller passed nothing (a trace recorded before
    # this feature has no key and the view guards on nil).
    def fingerprints_of(raw)
      return nil unless raw.is_a?(Hash) && !raw.empty?

      raw.each_with_object({}) do |(name, hex), acc|
        acc[name.to_s] = hex.to_s if hex.is_a?(String)
      end.then { |h| h.empty? ? nil : h }
    end

    # RFC-0030 C4: { hit_pct, cached_tokens, prompt_tokens, invalidation_reason }.
    # Unknown keys dropped. Present only when the caller passed it.
    def cache_of(raw)
      return nil unless raw.is_a?(Hash)

      c = {
        "hit_pct" => int_or_nil(raw[:hit_pct] || raw["hit_pct"]),
        "cached_tokens" => int(raw[:cached_tokens] || raw["cached_tokens"]),
        "prompt_tokens" => int(raw[:prompt_tokens] || raw["prompt_tokens"]),
        "invalidation_reason" => raw[:invalidation_reason] || raw["invalidation_reason"]
      }
      c["invalidation_reason"] = c["invalidation_reason"].to_s unless c["invalidation_reason"].nil?
      c
    end

    # Labels are {name, reason} in string keys (ContextFragment.label). A bare string
    # still reads as a nameless-reason label: an entry recorded before reasons existed,
    # or a caller that only has the id, degrades the card instead of poisoning it.
    def normalize_labels(raw)
      Array(raw).filter_map do |label|
        name, reason = label.is_a?(Hash) ? [label[:name] || label["name"], label[:reason] || label["reason"]] : [label, nil]
        next if name.to_s.empty?

        { "name" => name.to_s, "reason" => reason&.to_s }.compact
      end.uniq
    end

    def int(value) = Integer(value || 0)
    def int_or_nil(value) = value.nil? ? nil : Integer(value)
  end
end
