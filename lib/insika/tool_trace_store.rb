# frozen_string_literal: true

require "json"

module Insika
  # Per-session TOOL-CALL trace, for debugging in the Studio (FOLLOWUP §3.1). One
  # record per session in the raw backend (scope "tool_traces") — RUNTIME data, next
  # to sessions/tasks, NOT config (hence the raw `store:`, like SessionStore,
  # not the ConfigStore). A capped LIST of entries; ToolEnvelope writes one
  # per call (name + model args + result + status + ms). Serves
  # `/studio/sessions/:id`.
  #
  # SECURITY lives HERE (the store owns it): the screen is for the operator, but the
  # args/response may carry PII/credentials. Every write goes through mask (values of
  # sensitive keys become a sentinel) + clip (truncates large fields). The ephemeral
  # `data_tool_call` event (name+status, 0 leakage) still goes to the live cards;
  # THIS is the durable, richer record, behind the Studio login.
  class ToolTraceStore
    SCOPE = "tool_traces"
    MAX_PER_SESSION = 200                # tail per session (avoids growing without bound)
    MAX_FIELD_CHARS = 2_000              # cap per args/result field
    SECRET_KEY_RE = /token|secret|authorization|password|passwd|api[-_]?key|bearer|cookie/i

    def initialize(store:)
      @store = store
    end

    # Writes a (sanitized) entry into the session. Missing session_id -> no-op.
    # ToolEnvelope already guards, but so does this: the trace NEVER breaks the turn.
    def record(session_id:, entry:)
      sid = session_id.to_s
      return if sid.empty?

      list = (@store.get(SCOPE, sid) || []) + [sanitize(entry)]
      @store.set(SCOPE, sid, list.last(MAX_PER_SESSION))
    rescue StandardError
      nil
    end

    # -> [Hash] session entries in chronological order. [] if none.
    def for_session(session_id) = @store.get(SCOPE, session_id.to_s) || []

    # Discards a session's trace (cleanup). -> bool (did it exist?).
    def clear(session_id) = @store.delete(SCOPE, session_id.to_s)

    private

    def sanitize(entry)
      e = stringify_keys(entry)
      {
        "turn" => e["turn"], "tool" => e["tool"].to_s, "call_id" => e["call_id"].to_s,
        "ok" => ok?(e["result"]),
        "args" => clip(mask(e["args"])), "result" => clip(mask(e["result"])),
        "ms" => e["ms"], "at" => e["at"].to_s
      }
    end

    # Conventional tool error = Hash with key "error"/:error (everything else is ok).
    def ok?(result)
      !(result.is_a?(Hash) && (result.key?("error") || result.key?(:error)))
    end

    # Masks values of sensitive keys (recursive); the rest pass through intact.
    def mask(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = SECRET_KEY_RE.match?(k.to_s) ? SecretMasking::SENTINEL : mask(v)
        end
      when Array then obj.map { |v| mask(v) }
      else obj
      end
    end

    # -> Readable, capped String (JSON when structured). Truncates by CHARACTER
    # (not byte — avoids cutting UTF-8 mid-sequence).
    def clip(obj)
      s = obj.is_a?(String) ? obj : safe_json(obj)
      s.length > MAX_FIELD_CHARS ? "#{s[0, MAX_FIELD_CHARS]}…(truncado)" : s
    end

    def safe_json(obj)
      JSON.generate(obj)
    rescue StandardError
      obj.inspect
    end

    def stringify_keys(hash)
      (hash || {}).each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
