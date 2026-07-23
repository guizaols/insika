# frozen_string_literal: true

require_relative "message"

module Insika
  module Server
    module A2A
      # Task (core) -> A2A Task projection. PURE.
      module TaskProjection
        # State map. Unknown state -> "unknown".
        STATE = {
          queued: "submitted", running: "working", waiting: "input-required",
          paused: "working", completed: "completed", failed: "failed", cancelled: "canceled"
        }.freeze

        # task (TaskStore::Task) + content/error (String|nil) + at (ISO8601) -> Hash A2A Task.
        def self.call(task, at:, content: nil, error: nil)
          state = STATE.fetch(task.status.to_sym, "unknown")
          status = { state: state, timestamp: at }
          msg = status_message(state, content, error)
          status[:message] = msg if msg

          {
            id: task.id, contextId: task.session_id, kind: "task",
            status: status, artifacts: [], history: []
          }
        end

        # completed -> content; failed -> error; other states have no message.
        def self.status_message(state, content, error)
          case state
          when "completed" then content && Message.agent_message(content)
          when "failed"    then error && Message.agent_message(error)
          end
        end
        private_class_method :status_message
      end
    end
  end
end
