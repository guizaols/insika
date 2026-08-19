# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # a channel opt-out event (mapped by the integration)— or
    # the operator force-revoking a contact whose opt-out never arrived.
    # Revokes the contact cell AND cancels every pending record of that
    # customer in ONE transaction on the shared backend (D2: a half-cancelled
    # opt-out is the spam bug — a crash mid-revoke must leave the old state,
    # never the cell revoked with pending records alive). Blocked/fired
    # records are never touched. Tenant-scoped (WS1).
    class RevokeContact
      def initialize(contact_store:, followup_store:, store:, event_stream:)
        @contact_store = contact_store
        @followup_store = followup_store
        @store = store
        @event_stream = event_stream
      end

      # -> { customer:, tenant:, cancelled: }.
      def call(command)
        customer = Coercion.presence(command.payload[:customer] || command.payload["customer"])
        raise ValidationError, "customer is required" if customer.nil?

        tenant = command.meta[:tenant]
        # ONE transaction on the shared backend: both stores' writes (each
        # wrapped in their own nested transaction) join the outer one.
        cancelled = @store.transaction do
          @contact_store.set_revoked(tenant: tenant, customer: customer)
          @followup_store.cancel_pending_for(tenant: tenant, customer: customer)
        end

        @event_stream.emit(Insika::Event.new(
                             type: :contact_revoked,
                             data: { customer: customer, tenant: tenant },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        @event_stream.emit(Insika::Event.new(
                             type: :followups_cancelled,
                             data: { customer: customer, count: cancelled },
                             meta: { tenant: tenant, at: Time.now.utc.iso8601 }
                           ))
        { customer: customer, tenant: tenant, cancelled: cancelled }
      end
    end
  end
end
