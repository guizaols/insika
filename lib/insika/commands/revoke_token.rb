# frozen_string_literal: true

module Insika
  module Commands
    # WS1: revokes ONE token by id. The edge resolves tokens by hash, so the
    # plaintext is not needed to kill a credential. Idempotent: revoking an
    # already-revoked or unknown id -> { revoked: false }, never an error.
    # -> { id:, revoked: bool }.
    class RevokeToken
      def initialize(token_store:, event_stream:)
        @token_store = token_store
        @event_stream = event_stream
      end

      def call(command)
        raise Insika::ValidationError, "token commands are operator-only" if command.meta[:tenant]

        id = Insika::Coercion.presence(
          command.payload[:token_id] || command.payload["token_id"]
        )
        raise Insika::ValidationError, "token_id is required" if id.nil?

        revoked = @token_store.revoke(id)
        emit(id, revoked)
        { id: id, revoked: revoked }
      end

      private

      def emit(token_id, revoked)
        @event_stream.emit(Insika::Event.new(
                             type: :tenant_token_revoked,
                             data: { token_id: token_id, revoked: revoked },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end