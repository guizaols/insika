# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: forgets (removes) a fact from the
    # agent's memory. Idempotent: forgetting something that doesn't exist is not an error
    # (`existed: false`). Scoped by `tenant`. -> { existed: bool }.
    class MemoryForgetFact
      def initialize(memory_store:, event_stream:)
        @memory_store = memory_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        key = AgentPayload.presence(p[:key])
        raise Harness::ValidationError, "key is required" if key.nil?

        tenant = AgentPayload.presence(p[:tenant]) || command.meta[:tenant]
        existed = @memory_store.forget_fact(tenant: tenant, key: key)
        @event_stream.emit(Harness::Event.new(
                             type: :memory_fact_forgotten,
                             data: { tenant: tenant, key: key, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
