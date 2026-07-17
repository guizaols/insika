# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: writes a stable fact to the agent's
    # memory (MemoryStore, `profile` layer). Until now memory was only written
    # from WITHIN the turn (the `remember` tool); this Command is the HTTP surface the
    # Studio uses to edit facts directly. Scoped by `tenant` (nil = _default).
    # Synchronous; does not create a Task. -> Fact.
    class MemoryPutFact
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        key = AgentPayload.presence(p[:key])
        raise Harness::ValidationError, "key is required" if key.nil?
        raise Harness::ValidationError, "value is required" if p[:value].nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        fact = @memory_store.put_fact(tenant: tenant, key: key, value: p[:value])
        @event_stream.emit(Harness::Event.new(
                             type: :memory_fact_put,
                             data: { tenant: tenant, key: key },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        fact
      end
    end
  end
end
