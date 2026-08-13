# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (WS8, phase 2 — LGPD): purges what the engine holds about
    # ONE customer — the customer's memory cell, their sessions (found through
    # the `customer` var the Executor stamps on a tagged conversation) and the
    # per-session tool/context traces. The scope string IS the isolation
    # boundary, so zeroing it cannot touch another customer's or another
    # tenant's data. Operator-only BY CONSTRUCTION: the generic command ingress
    # is operator-grade (a tenant principal never reaches it).
    class ForgetCustomer
      def initialize(memory_store:, session_store:, tool_trace_store: nil,
                     context_trace_store: nil, event_stream:)
        @memory_store = memory_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @context_trace_store = context_trace_store
        @event_stream = event_stream
      end

      # -> { customer:, memory_records:, sessions: [] }.
      def call(command)
        customer = Coercion.presence(command.payload[:customer] || command.payload["customer"])
        raise ValidationError, "customer is required" if customer.nil?

        tenant = command.meta[:tenant]
        memory_scope = [tenant, customer].compact.join(":")
        memory_records = @memory_store.purge(tenant: memory_scope)

        sessions = session_ids_for(customer, tenant)
        sessions.each do |id|
          @tool_trace_store&.clear(id)
          @context_trace_store&.clear(id)
          @session_store.delete(id)
        end

        @event_stream.emit(Insika::Event.new(
                             type: :customer_forgotten,
                             data: { customer: customer, tenant: tenant,
                                     memory_records: memory_records, sessions: sessions },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { customer: customer, memory_records: memory_records, sessions: sessions }
      end

      private

      # The customer's sessions: the ones the Executor stamped with this
      # customer var — plus, in multi_tenant, only ids inside the tenant's
      # "<tenant>:" namespace (single_tenant sessions carry no prefix).
      def session_ids_for(customer, tenant)
        @session_store.each_id.each_with_object([]) do |id, acc|
          session = @session_store.find(id)
          next unless session
          next unless Coercion.presence(session.vars["customer"]).to_s == customer.to_s
          next if tenant && !id.to_s.start_with?("#{tenant}:")

          acc << id.to_s
        end
      end
    end
  end
end