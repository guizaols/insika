# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # A person's verdict on one guardrail flag, from the Studio: "reported"
    # (a false positive — whoever tunes the safety corpus picks it up from the
    # Review inbox), "resolved" (fixed), or nil to undo. The verdict lives on
    # the flag inside the session, so retention and tenant purges cover it.
    class ReviewGuardrailFlag
      def initialize(session_store:, event_stream:)
        @session_store = session_store
        @event_stream = event_stream
      end

      # -> { session_id:, message:, flag:, status: }
      def call(command)
        p = command.payload.transform_keys(&:to_s)
        sid = Coercion.presence(p["session_id"])
        raise ValidationError, "session_id is required" if sid.nil?

        message = Integer(p["message"], exception: false)
        flag = Integer(p["flag"], exception: false)
        raise ValidationError, "message and flag must be integers" if message.nil? || flag.nil?

        status = Coercion.presence(p["status"])
        @session_store.review_guardrail_flag(sid, message: message, flag: flag, status: status)
        @event_stream.emit(Insika::Event.new(
                             type: :guardrail_flag_reviewed,
                             data: { session_id: sid, message: message, flag: flag, status: status },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { session_id: sid, message: message, flag: flag, status: status }
      end
    end
  end
end
