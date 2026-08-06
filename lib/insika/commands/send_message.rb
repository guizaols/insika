# frozen_string_literal: true

module Insika
  module Commands
    # Canonical turn command: validates everything synchronously, creates the Task, fires
    # the fiber and responds `{task_id:}` immediately — the result flows through the Event
    # Stream. Validations that fail do NOT create a Task
    # (ValidationError/NotFoundError -> direct HTTP response).
    class SendMessage
      def initialize(profiles:, session_store:, task_store:, executor:)
        @profiles = ProfileSource.coerce(profiles)
        @session_store = session_store
        @task_store = task_store
        @executor = executor
      end

      def call(command)
        p = normalize(command.payload) # accepts string and symbol keys

        agent = p[:agent].to_s
        raise Insika::ValidationError, "agent is required" if agent.empty?

        profile = @profiles[agent] ||
                  (raise Insika::NotFoundError, "agent '#{agent}' not configured")

        message = p[:message]
        raise Insika::ValidationError, "message is required and non-empty" if message.to_s.strip.empty?

        # session_id XOR history (both -> error; neither -> one-shot).
        if p[:session_id] && p[:history]
          raise Insika::ValidationError, "session_id and history are mutually exclusive (D2)"
        end

        validate_history!(p[:history]) if p[:history]
# WHO wrote this message (MessageOrigin). Absent = a customer typed it, which
# is what a turn has always meant. Refused here rather than downstream: a
# typo'd origin would read as absent, and a marker that silently means
# "unmarked" is worse than none — it looks like the filtering is on.
Insika::MessageOrigin.parse!(p[:origin])
        if p[:session_id]
          @session_store.find(p[:session_id]) ||
            (raise Insika::NotFoundError, "session '#{p[:session_id]}' not found")
        end

        # command.to_h persists the entire Command in the Task;
        # ResumeTask re-reads payload.message from there.
        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn_in_session(task, profile: profile)
        { task_id: task.id }
      end

      private

      def normalize(payload)
        {
          agent: payload[:agent] || payload["agent"],
          message: payload[:message] || payload["message"],
          session_id: payload[:session_id] || payload["session_id"],
          history: payload[:history] || payload["history"],
origin: payload[:origin] || payload["origin"]
        }
      end

      def validate_history!(history)
        ok = history.is_a?(Array) && history.all? do |m|
          m.is_a?(Hash) &&
            !m.values_at(:role, "role").compact.empty? &&
            !m.values_at(:content, "content").compact.empty?
        end
        raise Insika::ValidationError, "history must be [{role:, content:}]" unless ok
      end
    end
  end
end
