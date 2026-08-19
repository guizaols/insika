# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command  the LGPD access right): exports what the
    # engine holds about ONE customer — their memory cell's facts + notes,
    # expired facts excluded. The FULL content is the RETURN VALUE (the Studio
    # turns it into a JSON download); the emitted event carries counts only, so
    # the event stream, the audit store and every log stay content-free (D7).
    # The return value never enters a store, an event or a log.
    class ExportCustomerMemory
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      # payload: { customer: (REQUIRED), tenant: } — customer from the payload
      # (an operator names the person); tenant from the payload || meta.
      # -> { "customer" =>, "tenant" =>, "exported_at" =>, "facts" => [Fact#to_h],
      #      "notes" => [Note#to_h], "counts" => { "facts" =>, "notes" => } }
      def call(command)
        p = AgentPayload.symbolize(command.payload)
        customer = AgentPayload.presence(p[:customer])
        raise Insika::ValidationError, "customer is required" if customer.nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        facts = @memory_store.facts(tenant: tenant, customer: customer)
        notes = @memory_store.notes(tenant: tenant, customer: customer)
        exported_at = Time.now.utc.iso8601

        @event_stream.emit(Insika::Event.new(
                             type: :customer_memory_exported,
                             data: { customer: customer, tenant: tenant,
                                     counts: { facts: facts.size, notes: notes.size } },
                             meta: { at: exported_at }
                           ))
        {
          "customer" => customer, "tenant" => tenant, "exported_at" => exported_at,
          "facts" => facts.map { |f| Coercion.deep_stringify(f.to_h) },
          "notes" => notes.map { |n| Coercion.deep_stringify(n.to_h) },
          "counts" => { "facts" => facts.size, "notes" => notes.size }
        }
      end
    end
  end
end