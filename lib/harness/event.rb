# frozen_string_literal: true

module Harness
  # Everything the runtime emits is an Event: a closed canonical catalog — new
  # types require updating the catalog.
  #
  # meta: { task_id:, session_id:, seq:, at: } (seq monotonic per task).
  # Terminal turn events are :task_completed / :task_failed / :task_cancelled.
  # :error is NOT a terminal twin — it survives only as the subscription-overflow
  # signal (EventStream) and the post-terminal failure report (fail_task).
  Event = Data.define(:type, :data, :meta) do
    def initialize(type:, data:, meta: {})
      super
    end

    def to_h = { type:, **data, meta: meta.compact }
  end
end
