# frozen_string_literal: true

module Insika
  module Commands
    # Control command: posts `:pause` to the Task's in-process
    # mailbox and responds synchronously. Payload `{ task_id: String }` -> returns Task.
    #
    # Cooperative: the one that transitions `running -> paused` and emits
    # `:task_paused` is the task's fiber when it drains at the next boundary — NEVER this
    # handler. Pausing a task with no live fiber (terminal/orphaned) is an idempotent no-op.
    class PauseTask
      def initialize(task_store:, executor:)
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        task_id = command.payload[:task_id] || command.payload["task_id"]
        raise Insika::ValidationError, "task_id is required" if task_id.to_s.empty?

        task = @task_store.find(task_id)
        raise Insika::NotFoundError, "task '#{task_id}' not found" unless task

        @executor.pause(task_id) # no-op if there is no live fiber in this process
        @task_store.find(task_id) # current state after the post
      end
    end
  end
end
