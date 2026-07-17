# frozen_string_literal: true

module Harness
  # Everything the runtime emits is an Event: a closed canonical catalog — new
  # types require updating the catalog.
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotonic per task).
  # :done and :error are kept by the contract with the consumer;
  # :task_completed/:task_failed are the correlated equivalents.
  Event = Data.define(:type, :data, :meta) do
    def initialize(type:, data:, meta: {})
      super
    end

    def to_h = { type:, **data, meta: meta.compact }
  end
end
