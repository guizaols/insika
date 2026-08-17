# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (WS8, phase 2 — LGPD): purges everything the engine holds
    # about ONE TENANT — its sessions (the "<tenant>:" namespace) and everything
    # those sessions left behind (traces, tasks, checkpoints, outbox deliveries
    # — see SessionPurge), every memory cell under the tenant (its own + the
    # customer cells), its outcome records (WS7) and its API CREDENTIALS (every
    # active token of the tenant is revoked first — an offboarded tenant must
    # not authenticate). The tenant string IS the
    # isolation boundary, so zeroing it cannot touch another tenant's data.
    # Operator-only BY CONSTRUCTION: the generic command ingress is
    # operator-grade (a tenant principal never reaches it).
    class DeleteTenantData
      include SessionPurge

      def initialize(memory_store:, session_store:, tool_trace_store: nil,
                     context_trace_store: nil, outcome_store: nil, task_store: nil,
                     checkpoint_store: nil, outbox_store: nil, shadow_pairs: nil,
                     token_store: nil, funnel_store: nil, event_stream:,
                     followup_store: nil, contact_store: nil)
        @memory_store = memory_store
        @token_store = token_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @context_trace_store = context_trace_store
        @outcome_store = outcome_store
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @outbox_store = outbox_store
        @shadow_pairs = shadow_pairs
        @funnel_store = funnel_store # RFC-0032 C6; nil = nothing to sweep
        @followup_store = followup_store # RFC-0033 C11; nil = nothing to sweep
        @contact_store = contact_store   # RFC-0033 C11; nil = nothing to sweep
        @event_stream = event_stream
      end

      # -> { tenant:, sessions:, memory_records:, outcomes:, tokens_revoked:,
      #      tasks:, checkpoints:, deliveries:, followups:, contacts: }.
      def call(command)
        tenant = Coercion.presence(command.payload[:tenant] || command.payload["tenant"])
        raise ValidationError, "tenant is required" if tenant.nil?

        # CREDENTIALS FIRST (WS1+WS8): erasing the data while the tenant's
        # tokens still resolve leaves an offboarded tenant authenticating and
        # opening a NEW session — the purge would report success over a live
        # customer. Revoking before the sweep closes the door, so nothing the
        # tenant does mid-purge survives it. nil store = single_tenant mode
        # (no per-tenant credential exists).
        tokens_revoked = @token_store ? @token_store.revoke_all(tenant_id: tenant) : 0

        sessions = @session_store.each_id.select { |id| id.to_s.start_with?("#{tenant}:") }
        purged = purge_sessions(sessions)

        memory_records = @memory_store.purge_tenant(tenant)
        outcomes = @outcome_store ? @outcome_store.purge(tenant: tenant) : 0
        funnel = @funnel_store ? @funnel_store.purge(tenant: tenant) : 0
        # RFC-0033 C11: the follow-up footprint dies with the tenant — records
        # and contact cells under the same tenant prefix.
        followups = @followup_store ? @followup_store.purge(tenant: tenant) : 0
        contacts = @contact_store ? @contact_store.purge(tenant: tenant) : 0

        @event_stream.emit(Insika::Event.new(
                             type: :tenant_data_deleted,
                             data: { tenant: tenant, sessions: sessions,
                                     memory_records: memory_records,
                                     outcomes: outcomes,
                                     funnel: funnel,
                                     followups: followups,
                                     contacts: contacts,
                                     tokens_revoked: tokens_revoked }.merge(purged),
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { tenant: tenant, sessions: sessions, memory_records: memory_records,
          outcomes: outcomes, funnel: funnel, followups: followups, contacts: contacts,
          tokens_revoked: tokens_revoked }.merge(purged)
      end
    end
  end
end
