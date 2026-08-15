# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (WS8, phase 2 — LGPD): purges what the engine holds about
    # ONE customer — the customer's memory cell, their sessions (found through
    # the `customer` var the Executor stamps on a tagged conversation) and
    # everything those sessions left behind (traces, tasks, checkpoints, outbox
    # deliveries — see SessionPurge). The scope string IS the isolation
    # boundary, so zeroing it cannot touch another customer's or another
    # tenant's data. Operator-only BY CONSTRUCTION: the generic command ingress
    # is operator-grade (a tenant principal never reaches it).
    #
    # WHICH TENANT is the whole correctness of the purge: the memory cell is
    # "memory:<tenant>:<customer>" and the sessions are the "<tenant>:" ones. It
    # is read from the command meta (an internal caller acting AS a tenant) or
    # from the payload (`{ customer:, tenant: }` — the operator naming it over
    # HTTP, where the principal has no tenant of its own). Absent from both, the
    # purge is deployment-wide: the untagged memory cell plus that customer's
    # sessions in EVERY tenant — right for a single-tenant deployment, and never
    # what a multi-tenant operator means, so they must name the tenant.
    class ForgetCustomer
      include SessionPurge

      def initialize(memory_store:, session_store:, tool_trace_store: nil,
                     context_trace_store: nil, task_store: nil, checkpoint_store: nil,
                     outbox_store: nil, shadow_pairs: nil, event_stream:)
        @memory_store = memory_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @context_trace_store = context_trace_store
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @outbox_store = outbox_store
        @shadow_pairs = shadow_pairs
        @event_stream = event_stream
      end

      # -> { customer:, tenant:, memory_records:, sessions: [], tasks:,
      #      checkpoints:, deliveries: }.
      def call(command)
        customer = Coercion.presence(command.payload[:customer] || command.payload["customer"])
        raise ValidationError, "customer is required" if customer.nil?

        tenant = command.meta[:tenant] ||
                 Coercion.presence(command.payload[:tenant] || command.payload["tenant"])
        memory_scope = [tenant, customer].compact.join(":")
        memory_records = @memory_store.purge(tenant: memory_scope)

        sessions = session_ids_for(customer, tenant)
        purged = purge_sessions(sessions)

        @event_stream.emit(Insika::Event.new(
                             type: :customer_forgotten,
                             data: { customer: customer, tenant: tenant,
                                     memory_records: memory_records,
                                     sessions: sessions }.merge(purged),
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { customer: customer, tenant: tenant, memory_records: memory_records,
          sessions: sessions }.merge(purged)
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
