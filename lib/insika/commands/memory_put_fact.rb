# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: writes a stable fact to the agent's
    # memory (MemoryStore, `profile` layer). Until now memory was only written
    # from WITHIN the turn (the `remember` tool); this Command is the HTTP surface the
    # Studio uses to edit facts directly. Scoped by `tenant` (nil = _default).
    # Synchronous; does not create a Task. -> Fact.
    #
    # RFC-0031: the OPERATOR surface — every write stamps `origin: "operator"`
    # (the `remember` tool keeps "engine") and, with an `audit_store:`
    # collaborator, appends a content-free audit line (old/new digests). The
    # audit is optional: nil = no audit (specs, minimal graphs).
    class MemoryPutFact
      def initialize(memory_store:, event_stream:, audit_store: nil)
        @memory_store = memory_store
        @event_stream = event_stream
        @audit_store = audit_store
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        key = AgentPayload.presence(p[:key])
        raise Insika::ValidationError, "key is required" if key.nil?
        raise Insika::ValidationError, "value is required" if p[:value].nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        customer = AgentPayload.presence(p[:customer])
        operator = AgentPayload.presence(p[:operator]) || command.meta[:operator] || "operator"

        scope = @memory_store.cell_for(tenant, customer)
        old = @memory_store.get_fact(tenant: tenant, key: key, customer: customer)
        fact = @memory_store.put_fact(tenant: tenant, key: key, value: p[:value],
                                      customer: customer, origin: "operator",
                                      expires_at: AgentPayload.presence(p[:expires_at]))
        @audit_store&.record(
          cell: scope, action: "put", actor: operator, key: key,
          tenant: tenant, customer: customer,
          old_hash: old && MemoryAuditStore.digest(old.value),
          new_hash: MemoryAuditStore.digest(fact.value)
        )
        @event_stream.emit(Insika::Event.new(
                             type: :memory_fact_put,
                             data: { tenant: tenant, key: key, customer: customer }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        fact
      end
    end
  end
end