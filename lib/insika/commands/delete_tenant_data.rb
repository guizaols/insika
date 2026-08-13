# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command (WS8, phase 2 — LGPD): purges everything the engine holds
    # about ONE TENANT — its sessions (the "<tenant>:" namespace) and everything
    # those sessions left behind (traces, tasks, checkpoints, outbox deliveries
    # — see SessionPurge), every memory cell under the tenant (its own + the
    # customer cells) and its outcome records (WS7). The tenant string IS the
    # isolation boundary, so zeroing it cannot touch another tenant's data.
    # Operator-only BY CONSTRUCTION: the generic command ingress is
    # operator-grade (a tenant principal never reaches it).
    class DeleteTenantData
      include SessionPurge

      def initialize(memory_store:, session_store:, tool_trace_store: nil,
                     context_trace_store: nil, outcome_store: nil, task_store: nil,
                     checkpoint_store: nil, outbox_store: nil, event_stream:)
        @memory_store = memory_store
        @session_store = session_store
        @tool_trace_store = tool_trace_store
        @context_trace_store = context_trace_store
        @outcome_store = outcome_store
        @task_store = task_store
        @checkpoint_store = checkpoint_store
        @outbox_store = outbox_store
        @event_stream = event_stream
      end

      # -> { tenant:, sessions:, memory_records:, outcomes:, tasks:,
      #      checkpoints:, deliveries: }.
      def call(command)
        tenant = Coercion.presence(command.payload[:tenant] || command.payload["tenant"])
        raise ValidationError, "tenant is required" if tenant.nil?

        sessions = @session_store.each_id.select { |id| id.to_s.start_with?("#{tenant}:") }
        purged = purge_sessions(sessions)

        memory_records = @memory_store.purge_tenant(tenant)
        outcomes = @outcome_store ? @outcome_store.purge(tenant: tenant) : 0

        @event_stream.emit(Insika::Event.new(
                             type: :tenant_data_deleted,
                             data: { tenant: tenant, sessions: sessions,
                                     memory_records: memory_records,
                                     outcomes: outcomes }.merge(purged),
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { tenant: tenant, sessions: sessions,
          memory_records: memory_records, outcomes: outcomes }.merge(purged)
      end
    end
  end
end
