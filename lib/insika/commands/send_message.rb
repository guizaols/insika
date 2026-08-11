# frozen_string_literal: true

module Insika
  module Commands
    # Canonical turn command: validates everything synchronously, creates the Task, fires
    # the fiber and responds `{task_id:}` immediately — the result flows through the Event
    # Stream. Validations that fail do NOT create a Task
    # (ValidationError/NotFoundError -> direct HTTP response).
    class SendMessage
      # surfaces whose response can carry the "you do not own the reply"
      # verdict (`merged` for `collect`, `steered` for `steer`), and therefore the only
      # ones where a message may join another turn. `/v1/responses` is NOT here: its body
      # is OpenAI-shaped SSE with nowhere to put the field, and it is frozen because a
      # live consumer speaks it. Joining a caller that cannot hear the verdict makes it
      # deliver the same answer once per message, which is worse than not joining at all.
      # Channels declare themselves by `channel:<id>` once lands.
      COALESCABLE_TRANSPORTS = %i[http:json].freeze

      # `inbound_log` is the retry window for channel event ids.
      # nil = no dedup (every surface that does not send an `event_id`, which is all
      # of them today), and a caller that cannot supply a stable id gets
      # at-least-once turns rather than a content hash pretending to be dedup.
      def initialize(profiles:, session_store:, task_store:, executor:, inbound_log: nil)
        @profiles = ProfileSource.coerce(profiles)
        @session_store = session_store
        @task_store = task_store
        @executor = executor
        @inbound_log = inbound_log
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
          raise Insika::ValidationError, "session_id and history are mutually exclusive"
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

        # the platform retried a webhook it already delivered. Answer
        # with the turn it ALREADY produced and run nothing: without this, one flaky
        # ack costs a second LLM turn and sends the customer the same answer twice.
        # Checked before the queue doors on purpose — a duplicate is not a fragment to
        # merge and not a correction to steer with, it is the same message again.
        key = dedup_key(command, p)
        if key && (prior = @inbound_log.find(key))
          return { task_id: prior, duplicate: true }
        end

        result = start_turn(command, p, profile)
        @inbound_log.record(key, result[:task_id]) if key
        result
      end

      private

      # The turn (or the verdict that this message joined someone else's).
      def start_turn(command, p, profile)
        message = p[:message]

        # a fragment for a session whose turn is still at the door
        # joins it instead of becoming a turn of its own. Asked BEFORE `create` so a
        # merge leaves no orphan :queued task behind (Recovery replays :queued at
        # boot). Only offered on a surface that can report the verdict back —
        # coalescing a caller that cannot hear `merged` makes it deliver the
        # same answer twice.
        if coalescable?(command)
          if (joined = @executor.collect_into_pending(p[:session_id], message, profile: profile))
            return { task_id: joined, merged: true }
          end

          # the turn is already RUNNING: the message is appended to it at
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
        # `interrupt` mode: the turn in flight is now answering the wrong
        # question, so it is abandoned at its next boundary. This message keeps its OWN
        # task and its own reply (that is why it needs no verdict and no surface gate), and
        # the cancel is posted after `create` so the event can name what replaced what.
        # No-op in every other mode.
        @executor.interrupt_running(p[:session_id], profile: profile, replaced_by: task.id)
        @executor.spawn_in_session(task, profile: profile)
        { task_id: task.id }
      end

      def coalescable?(command)
        transport = command.meta[:transport]
        COALESCABLE_TRANSPORTS.include?(transport) || transport.to_s.start_with?("channel:")
      end

      # Scoped by TRANSPORT, never bare: two channels are two consumers with two id
      # spaces, and a Slack event id that happened to equal a `wamid` would otherwise
      # silence a real message. nil (no log wired, or no id sent) = no dedup.
      def dedup_key(command, payload)
        return nil unless @inbound_log

        event_id = Coercion.presence(payload[:event_id])
        event_id && "#{command.meta[:transport]}:#{event_id}"
      end

      def normalize(payload)
        {
          agent: payload[:agent] || payload["agent"],
          message: payload[:message] || payload["message"],
          session_id: payload[:session_id] || payload["session_id"],
          history: payload[:history] || payload["history"],
          origin: payload[:origin] || payload["origin"],
          event_id: payload[:event_id] || payload["event_id"]
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
