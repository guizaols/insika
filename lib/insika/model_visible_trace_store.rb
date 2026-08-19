# frozen_string_literal: true

module Insika
  #   — the durable half of the conformance claim: what the model
  # received, per (task, turn), captured at the RubyLLM boundary and persisted.
  #
  # One record per (task, turn, part) under the scope "model_visible_traces",
  # key "model_visible:<task_id>:turn:<n>:<part>" — `part` separates the
  # turn's own ask ("turn") from engine-internal asks that are model-visible
  # too (the WS4 routing classifier, "routing").
  #
  # A TRACE, best-effort by construction: `record` rescues everything -> nil
  # (a log must never break a turn — the house rule, tool_trace_store.rb).
  # The record is an UPSERT by (task, turn, part): a resumed turn re-records
  # its ask in place (the ContextTraceStore idiom), never duplicates.
  class ModelVisibleTraceStore
    SCOPE = "model_visible_traces"

    def initialize(store:)
      @store = store
    end

    # -> ModelVisible | nil (nil = the record failed — the turn proceeds).
    def record(task_id:, turn:, part: "turn", payload:)
      return nil if payload.nil?

      @store.set(SCOPE, key(task_id, turn, part), payload.to_h)
      payload
    rescue StandardError
      nil
    end

    # -> ModelVisible | nil.
    def find(task_id, turn:, part: "turn")
      raw = @store.get(SCOPE, key(task_id, turn, part))
      raw && ModelVisible.from_h(raw)
    end

    # -> [ModelVisible] the task's records for `part`, ordered by turn.
    def for_task(task_id, part: "turn")
      @store.list(SCOPE, key_prefix(task_id)).filter_map do |k|
        next unless k.end_with?(":#{part}")

        n = k[/:turn:(\d+):/, 1]
        n && [Integer(n), ModelVisible.from_h(@store.get(SCOPE, k))]
      end.sort_by(&:first).map(&:last)
    end

    # Removes every record for a task (retention/LGPD). -> Integer (removed).
    def purge(task_id)
      keys = @store.list(SCOPE, key_prefix(task_id))
      keys.each { |k| @store.delete(SCOPE, k) }
      keys.size
    end

    private

    def key(task_id, turn, part)
      "model_visible:#{task_id}:turn:#{Integer(turn)}:#{part}"
    end

    def key_prefix(task_id)
      "model_visible:#{task_id}:turn:"
    end
  end
end
