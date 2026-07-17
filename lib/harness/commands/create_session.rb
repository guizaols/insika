# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: creates a session and responds synchronously —
    # does not create a Task. Payload `{ vars: {} }` -> returns Session. `id` optional:
    # when present, the session is born with that id (correlation by external key —
    # e.g.: chat.id in the /v1/responses adapter; contextId in A2A). Absent -> uuid.
    class CreateSession
      # event_stream: any object with #emit(event) (tests use a spy).
      def initialize(session_store:, event_stream:)
        @session_store = session_store
        @event_stream = event_stream
      end

      def call(command)
        # Accepts a symbol key (internal dispatch) and a string key (transport JSON)
        # — normalizes at the handler boundary.
        vars = command.payload[:vars] || command.payload["vars"] || {}
        raise Harness::ValidationError, "vars must be a Hash" unless vars.is_a?(Hash)

        id = command.payload[:id] || command.payload["id"]
        session = id ? @session_store.create(id: id, vars: vars) : @session_store.create(vars: vars)
        # :session_created is from the closed catalog (origin: CreateSession handler).
        # meta without task_id/seq (control has no Task); Event#to_h does meta.compact.
        @event_stream.emit(Harness::Event.new(
                             type: :session_created,
                             data: { session_id: session.id },
                             meta: { session_id: session.id, at: Time.now.utc.iso8601 }
                           ))
        session
      end
    end
  end
end
