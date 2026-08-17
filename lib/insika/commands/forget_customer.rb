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
                     outbox_store: nil, shadow_pairs: nil, audit_store: nil, event_stream:,
                     followup_store: nil, contact_store: nil, proposal_store: nil)
        @memory_store = memory_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @context_trace_store = context_trace_store
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @outbox_store = outbox_store
        @shadow_pairs = shadow_pairs
        @audit_store = audit_store
        @event_stream = event_stream
        @followup_store = followup_store # RFC-0033 C11; nil = nothing to sweep
        @contact_store = contact_store   # RFC-0033 C11; nil = nothing to sweep
        @proposal_store = proposal_store # RFC-0034 C8; nil = nothing to sweep
      end

      # -> { customer:, tenant:, memory_records:, sessions: [], tasks:,
      #      checkpoints:, deliveries:, followups:, contacts: }.
      def call(command)
        customer = Coercion.presence(command.payload[:customer] || command.payload["customer"])
        raise ValidationError, "customer is required" if customer.nil?

        tenant = command.meta[:tenant] ||
                 Coercion.presence(command.payload[:tenant] || command.payload["tenant"])
        memory_scope = [tenant, customer].compact.join(":")
        memory_records = @memory_store.purge(tenant: memory_scope)

        # RFC-0033 C11: the follow-up footprint dies with the person — the
        # schedule records and the contact cell (LGPD).
        followups = @followup_store&.purge_customer(tenant: tenant, customer: customer) || 0
        contacts = @contact_store&.delete(tenant: tenant, customer: customer) ? 1 : 0

        # RFC-0034 C8: the distilled PROPOSALS die with the person — a proposal
        # is born inside a customer cell (D6), so forget_customer reaches it.
        proposals = @proposal_store&.purge_customer(tenant: tenant, customer: customer) || 0

        sessions = session_ids_for(customer, tenant)
        purged = purge_sessions(sessions)

        # RFC-0031: the audit records the thing that happened, content-free —
        # a digest-free line with the counts (the deleted VALUES never enter
        # the audit store). Written AFTER the purge, so the line describes a
        # deletion that actually happened. nil audit_store = no-op.
        @audit_store&.record(
          cell: @memory_store.cell_for(tenant, customer),
          action: "purge", actor: operator(command), tenant: tenant, customer: customer,
          note: "memory_records: #{memory_records}, sessions: #{sessions.size}"
        )

        @event_stream.emit(Insika::Event.new(
                             type: :customer_forgotten,
                             data: { customer: customer, tenant: tenant,
                                     memory_records: memory_records,
                                     sessions: sessions,
                                     followups: followups,
                                     contacts: contacts,
                                     proposals: proposals }.merge(purged),
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { customer: customer, tenant: tenant, memory_records: memory_records,
          sessions: sessions, followups: followups, contacts: contacts,
          proposals: proposals }.merge(purged)
      end

      private

      def operator(command)
        Coercion.presence(command.payload[:operator] || command.payload["operator"]) || "operator"
      end

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
