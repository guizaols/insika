# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: the operator resolves a pending action
    # (human-in-the-loop). Resolves the PendingAction in the store (durable source
    # of truth) and WAKES the turn suspended on :waiting by posting :approval to the
    # live fiber. Order matters: RESOLVE before posting — when the await wakes, the
    # store already has the decision (request_approval re-reads it from there). Crash-safe:
    # with no live fiber the post is a no-op; recovery re-executes and uses the durable decision.
    #
    # Payload `{ pending_id:, decision: "approved"|"rejected", operator?: }`.
    # -> resolved PendingAction.
    class ApproveAction
      def initialize(pending_action_store:, executor:, event_stream:)
        @pending_action_store = pending_action_store
        @executor = executor
        @event_stream = event_stream
      end

      def call(command)
        p = command.payload
        pending_id = (p[:pending_id] || p["pending_id"]).to_s
        decision = (p[:decision] || p["decision"]).to_s
        raise Harness::ValidationError, "pending_id is required" if pending_id.empty?

        # operator: from the operator's auth (Control UI) via payload; nil ok.
        operator = p[:operator] || p["operator"] || command.meta[:operator]

        # resolve() validates the decision and the state (:pending); NotFound if absent.
        resolved = @pending_action_store.resolve(pending_id, decision: decision, operator: operator)

        @executor.approve(resolved.task_id) # wakes the live fiber (no-op if it crashed)
        @event_stream.emit(Harness::Event.new(
                             type: :approval_resolved,
                             data: { pending_id: pending_id, decision: resolved.status,
                                     task_id: resolved.task_id, resolved_by: operator },
                             meta: { task_id: resolved.task_id, at: Time.now.utc.iso8601 }
                           ))
        resolved
      end
    end
  end
end
