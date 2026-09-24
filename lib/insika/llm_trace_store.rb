# frozen_string_literal: true

module Insika
  # Content-free native diagnostics. Task deletion owns their lifetime.
  class LLMTraceStore
    SCOPE = "llm_traces"
    MAX_PER_TASK = 200
    TEXT_FIELDS = %w[type operation provider model status request_id exception_class at].freeze
    NUMBER_FIELDS = %w[turn duration_ms input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens cost].freeze

    def initialize(store:)
      @store = store
    end

    # Also used at the telemetry boundary; never stringify arbitrary objects.
    def self.sanitize(entry)
      entry.each_with_object({}) do |(key, value), result|
        if TEXT_FIELDS.include?(key) && value.is_a?(String)
          result[key] = Coercion.utf8(value)[0, 256].gsub(/[[:cntrl:]]/, "")
        elsif NUMBER_FIELDS.include?(key) && (value.nil? ||
              ((value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value >= 0 && value <= 1e18))
          result[key] = value
        end
      end
    end

    def record(task_id:, entry:)
      @store.transaction do
        next unless @store.get(TaskStore::SCOPE, "#{TaskStore::KEY_PREFIX}#{task_id}")

        trace = for_task(task_id)
        entries = trace["entries"] + [self.class.sanitize(entry)]
        @store.set(SCOPE, task_id.to_s, {
          "entries" => entries.last(MAX_PER_TASK),
          "truncated" => trace["truncated"] || entries.size > MAX_PER_TASK
        })
      end
    rescue StandardError
      nil
    end

    def for_task(task_id)
      @store.get(SCOPE, task_id.to_s) || { "entries" => [], "truncated" => false }
    end

    def clear(task_id) = @store.delete(SCOPE, task_id.to_s)
  end
end
