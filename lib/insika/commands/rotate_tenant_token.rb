# frozen_string_literal: true

module Insika
  module Commands
    # WS1: rotates a tenant's credential — revokes every active token of the
    # tenant and issues a fresh one, in ONE transaction (a crashed half-rotation
    # must never leave the tenant with nothing valid). Only the tenant's own
    # tokens are touched; the operator token and other tenants are untouched.
    # -> { revoked: n, token: Issue.to_h }.
    class RotateTenantToken
      def initialize(token_store:, event_stream:)
        @token_store = token_store
        @event_stream = event_stream
      end

      def call(command)
        raise Insika::ValidationError, "token commands are operator-only" if command.meta[:tenant]

        tenant_id = Insika::Coercion.presence(
          command.payload[:tenant_id] || command.payload["tenant_id"]
        )
        raise Insika::ValidationError, "tenant_id is required" if tenant_id.nil?

        label = command.payload[:label] || command.payload["label"] || "default"
        result = @token_store.rotate(tenant_id: tenant_id, label: label)
        issue = result[:issue]
        emit(issue.id, tenant_id, result[:revoked])
        { revoked: result[:revoked],
          token: { token: issue.token, id: issue.id, tenant_id: tenant_id, label: label.to_s } }
      end

      private

      def emit(token_id, tenant_id, revoked)
        @event_stream.emit(Insika::Event.new(
                             type: :tenant_token_rotated,
                             data: { token_id: token_id, tenant_id: tenant_id, revoked: revoked },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end