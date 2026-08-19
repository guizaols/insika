# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: forgets (removes) a fact from the
    # agent's memory. Idempotent: forgetting something that doesn't exist is not an error
    # (`existed: false`). Scoped by `tenant`. -> { existed: bool }.
    #
    # with an `audit_store:` collaborator, appends a content-free
    # audit line (old_hash only — the deleted value's digest, never the
    # value). Optional: nil = no audit.
    class MemoryForgetFact
      def initialize(memory_store:, event_stream:, audit_store: nil)
        @memory_store = memory_store
        @event_stream = event_stream
        @audit_store = audit_store
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        key = AgentPayload.presence(p[:key])
        raise Insika::ValidationError, "key is required" if key.nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        customer = AgentPayload.presence(p[:customer])
        operator = AgentPayload.presence(p[:operator]) || command.meta[:operator] || "operator"

        scope = @memory_store.cell_for(tenant, customer)
        old = @memory_store.get_fact(tenant: tenant, key: key, customer: customer)
        existed = @memory_store.forget_fact(tenant: tenant, key: key, customer: customer)
        @audit_store&.record(
          cell: scope, action: "forget", actor: operator, key: key,
          tenant: tenant, customer: customer,
          old_hash: old && MemoryAuditStore.digest(old.value)
        )
        @event_stream.emit(Insika::Event.new(
                             type: :memory_fact_forgotten,
                             data: { tenant: tenant, key: key, customer: customer,
                                     existed: existed }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end