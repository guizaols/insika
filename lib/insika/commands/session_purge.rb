# frozen_string_literal: true

module Insika
  module Commands
    # The CONVERSATION footprint of a session, purged (WS8/LGPD). Shared by
    # `forget_customer` and `delete_tenant_data` because "erase this person"
    # and "erase this tenant" differ only in WHICH sessions they name — what a
    # session leaves behind is the same list, and a second copy of that list is
    # a second thing to forget to update.
    #
    # Deleting the session record alone is NOT erasure: the customer's own text
    # lives in the task's persisted command payload, the whole transcript lives
    # in the turn's checkpoints, and the answer as it was handed to the channel
    # lives in the outbox record's payload. All four go together or none of them
    # counts.
    #
    # A task is deleted whatever its status — this is a deletion order, not the
    # retention sweep (which spares live tasks on purpose). The stores it needs
    # beyond the session are optional (deployment components): a graph without
    # them purges what it has and reports zero for the rest.
    module SessionPurge
      # ids: the session ids to erase. -> { tasks:, checkpoints:, deliveries:, pairs: }
      def purge_sessions(ids)
        ids = Array(ids).map(&:to_s)
        return { tasks: 0, checkpoints: 0, deliveries: 0, pairs: 0 } if ids.empty?

        tasks, checkpoints = purge_tasks_of(ids)
        deliveries = @outbox_store ? @outbox_store.purge_sessions(ids) : 0
        pairs = @shadow_pairs ? @shadow_pairs.purge_sessions(ids) : 0
        ids.each do |id|
          @tool_trace_store&.clear(id)
          @context_trace_store&.clear(id)
          @session_store.delete(id)
        end
        { tasks: tasks, checkpoints: checkpoints, deliveries: deliveries, pairs: pairs }
      end

      private

      # -> [tasks removed, checkpoint records removed]. The id list is
      # SNAPSHOTTED (`to_a`) before the deletes: `each_id` enumerates the
      # backend's keys lazily, and deleting under it would skip records.
      def purge_tasks_of(ids)
        return [0, 0] unless @task_store

        wanted = ids.each_with_object({}) { |id, acc| acc[id] = true }
        tasks = 0
        checkpoints = 0
        @task_store.each_id.to_a.each do |task_id|
          task = @task_store.find(task_id)
          next unless task && wanted[task.session_id.to_s]

          checkpoints += @checkpoint_store ? @checkpoint_store.purge(task_id) : 0
          @task_store.delete(task_id)
          tasks += 1
        end
        [tasks, checkpoints]
      end
    end
  end
end
