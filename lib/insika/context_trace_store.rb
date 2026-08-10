# frozen_string_literal: true

module Insika
  # Per-session CONTEXT trace, for the Studio's breakdown-by-category card
  # (RFC-0023). One record per session in the raw backend (scope
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
    # no-op.
    def record(session_id:, entry:)
      sid = session_id.to_s
      return if sid.empty?

      e = sanitize(entry)
      key = [e["task_id"], e["turn"]]
      list = (@store.get(SCOPE, sid) || []).reject { |x| [x["task_id"], x["turn"]] == key } + [e]
      @store.set(SCOPE, sid, list.last(MAX_PER_SESSION))
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
          acc[name.to_s] = { "tokens" => int(c[:tokens] || c["tokens"]),
                             "fragments" => int(c[:fragments] || c["fragments"]),
                             "pinned" => int(c[:pinned] || c["pinned"]) }
        end,
        "tools" => { "count" => int(tools[:count] || tools["count"]),
                     "tokens" => int(tools[:tokens] || tools["tokens"]) }
      }
    end

    def int(value) = Integer(value || 0)
  end
end
