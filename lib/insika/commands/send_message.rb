# frozen_string_literal: true

module Insika
  module Commands
    # Canonical turn command: validates everything synchronously, creates the Task, fires
    # the fiber and responds `{task_id:}` immediately — the result flows through the Event
    # Stream. Validations that fail do NOT create a Task
    # (ValidationError/NotFoundError -> direct HTTP response).
    class SendMessage
      # RFC-0015 §5.5 — surfaces whose response can carry the "you do not own the reply"
      # verdict (`merged` for `collect`, `steered` for `steer`), and therefore the only
      # ones where a message may join another turn. `/v1/responses` is NOT here: its body
      # is OpenAI-shaped SSE with nowhere to put the field, and it is frozen because a
      # live consumer speaks it. Joining a caller that cannot hear the verdict makes it
      # deliver the same answer once per message, which is worse than not joining at all.
      # Channels declare themselves by `channel:<id>` once RFC-0011 §6 lands.
      COALESCABLE_TRANSPORTS = %i[http:json].freeze

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

        # RFC-0015 §5.3 — a fragment for a session whose turn is still at the door
        # joins it instead of becoming a turn of its own. Asked BEFORE `create` so a
        # merge leaves no orphan :queued task behind (Recovery replays :queued at
        # boot). Only offered on a surface that can report the verdict back —
        # §5.5: coalescing a caller that cannot hear `merged` makes it deliver the
        # same answer twice.
        if coalescable?(command)
          if (joined = @executor.collect_into_pending(p[:session_id], message, profile: profile))
            return { task_id: joined, merged: true }
          end

          # RFC-0015 §5.1 — the turn is already RUNNING: the message is appended to it at
          # the next tool-batch boundary. Same verdict as a merge, different word: the
          # answer comes out of `task_id`, which is not this call's to deliver. Asked
          # after `collect` because the two cannot both apply — a turn is either still at
          # the door or running.
          if (steered = @executor.steer_into_running(p[:session_id], message, profile: profile))
            return { task_id: steered, steered: true }
          end
        end

        # command.to_h persists the entire Command in the Task;
        # ResumeTask re-reads payload.message from there.
        task = @task_store.create(command: command.to_h, session_id: p[:session_id])
        @executor.spawn_in_session(task, profile: profile)
        { task_id: task.id }
      end

      private

      def coalescable?(command)
        transport = command.meta[:transport]
        COALESCABLE_TRANSPORTS.include?(transport) || transport.to_s.start_with?("channel:")
      end

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
