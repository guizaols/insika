# frozen_string_literal: true

module Insika
  module Commands
    # WS1: issues a PER-TENANT token (multi_tenant mode). Operator-only BY
    # CONSTRUCTION: the edge refuses a tenant principal on POST /v1/commands
    # (403), and an internal command stamped with a tenant is refused here —
    # a tenant can never mint credentials. The plaintext token is the response
    # and exists nowhere else; the store keeps only its hash. -> Issue.to_h.
    class IssueTenantToken
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
        issue = @token_store.issue(tenant_id: tenant_id, label: label)
        emit(issue.id, tenant_id)
        { token: issue.token, id: issue.id, tenant_id: tenant_id, label: label.to_s }
      end

      private

      def emit(token_id, tenant_id)
        @event_stream.emit(Insika::Event.new(
                             type: :tenant_token_issued,
                             data: { token_id: token_id, tenant_id: tenant_id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end