# frozen_string_literal: true

module Insika
  module Commands
    # Control command: posts `:cancel` to the Task's in-process mailbox
    # and responds synchronously. Payload `{ task_id: String }` -> returns Task.
    #
    # Cancellation is COOPERATIVE: the one that transitions the status is the
    # task's fiber when it drains the mailbox — NEVER this handler. Cancelling a task with no
    # live fiber (terminal or orphaned) is an idempotent no-op.
    class CancelTask
      # executor: object with #cancel(task_id) — the real implementation is
      # `@running[task_id]&.post(:cancel)`; here it's a contract (duck type).
      def initialize(task_store:, executor:)
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        task_id = command.payload[:task_id] || command.payload["task_id"]
        raise Insika::ValidationError, "task_id is required" if task_id.to_s.empty?

        task = @task_store.find(task_id)
        raise Insika::NotFoundError, "task '#{task_id}' not found" unless task

        @executor.cancel(task_id) # no-op if there is no live fiber in this process
        # Does not transition status nor touch the persisted mailbox_state: it only uses
        # the in-process mailbox (Async::Queue). Returns the current state after the post.
        @task_store.find(task_id)
      end
    end
  end
end
