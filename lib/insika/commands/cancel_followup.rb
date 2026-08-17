# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # RFC-0033 C6: the operator cancels ONE pending follow-up record (the
    # Studio's Cancel button dispatches this). Synchronous control command (no
    # task, like RecordOutcome); idempotent — an already-cancelled record
    # returns as-is (a repeat of the same call is not an error). Tenant-scoped
    # (WS1): a tenant principal can only cancel its own tenant's records.
    class CancelFollowup
      def initialize(followup_store:, event_stream:)
        @followup_store = followup_store
        @event_stream = event_stream
      end

      # -> Record. Emits :followup_cancelled { id:, cancelled_by: }.
      def call(command)
        id = Coercion.presence(command.payload[:followup_id] || command.payload["followup_id"])
        raise ValidationError, "followup_id is required" if id.nil?

        record = @followup_store.find(id)
        raise NotFoundError, "follow-up not found: #{id}" if record.nil?

        # WS1: the principal's tenant is the scope — a tenant token cannot
        # cancel another tenant's record by id.
        tenant = command.meta[:tenant]
        unless record.tenant == (tenant.to_s.empty? ? "platform" : tenant.to_s)
          raise ValidationError, "follow-up #{id} belongs to another tenant"
        end

        # A non-pending record (the tick fired it between the render and the
        # click) is a domain error the Studio can flash — never a 500.
        cancelled = begin
          @followup_store.cancel(id: id)
        rescue ArgumentError => e
          raise ValidationError, e.message
        end
        @event_stream.emit(Insika::Event.new(
                             type: :followup_cancelled,
                             data: { id: cancelled.id, cancelled_by: "operator" },
                             meta: { tenant: command.meta[:tenant], at: Time.now.utc.iso8601 }
                           ))
        cancelled
      end
    end
  end
end
