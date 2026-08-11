# frozen_string_literal: true

require "time"

module Insika
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
        raise Insika::ValidationError, "vars must be a Hash" unless vars.is_a?(Hash)

        # Per-chat model pin: `model`/`provider` on the payload become a
        # reserved, collision-safe slot in vars (never rendered in the prompt — the
        # Request provider skips "__"-prefixed vars). The ModelResolver reads it as
        # the highest-precedence layer (Chat > Agent > platform default).
        vars = apply_model_pin(vars.dup, command.payload)

        id = command.payload[:id] || command.payload["id"]
        session = id ? @session_store.create(id: id, vars: vars) : @session_store.create(vars: vars)
        # :session_created is from the closed catalog (origin: CreateSession handler).
        # meta without task_id/seq (control has no Task); Event#to_h does meta.compact.
        @event_stream.emit(Insika::Event.new(
                             type: :session_created,
                             data: { session_id: session.id },
                             meta: { session_id: session.id, at: Time.now.utc.iso8601 }
                           ))
        session
      end

      private

      # Reads `model`/`provider`/`thinking` (string|symbol keys) and, when any is
      # present, writes the reserved vars slot. All must be strings; `thinking` is
      # the per-chat reasoning override (off/on/low/medium/high) and may be set
      # WITHOUT a model pin. Absent -> vars unchanged.
      def apply_model_pin(vars, payload)
        model = payload[:model] || payload["model"]
        provider = payload[:provider] || payload["provider"]
        thinking = payload[:thinking] || payload["thinking"]
        return vars if model.nil? && provider.nil? && thinking.nil?

        raise Insika::ValidationError, "model must be a String" unless model.nil? || model.is_a?(String)
        raise Insika::ValidationError, "provider must be a String" unless provider.nil? || provider.is_a?(String)
        raise Insika::ValidationError, "thinking must be a String" unless thinking.nil? || thinking.is_a?(String)

        pin = {}
        pin["model"] = model if model
        pin["provider"] = provider if provider
        pin["thinking"] = thinking if thinking
        vars[Insika::ModelResolver::SESSION_SLOT] = pin
        vars
      end
    end
  end
end
