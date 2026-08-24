# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: restores an old version of a concept as the current
    # content (a new write — linear history, like `RestoreSystemFile`).
    # -> { name, agent, tenant, updated_at }.
    class RestoreConcept
      def initialize(knowledge_store:, event_stream:)
        @knowledge_store = knowledge_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        agent = AgentPayload.presence(p[:agent])
        tenant = AgentPayload.presence(p[:tenant])
        raise Insika::ValidationError, "name is required" if name.nil?
        raise Insika::ValidationError, "agent is required" if agent.nil?
        raise Insika::ValidationError, "version is required" if p[:version].nil?

        rec = @knowledge_store.restore(agent, name, p[:version], tenant: tenant)
        @event_stream.emit(Insika::Event.new(
                             type: :knowledge_learned, data: { name: name, agent: agent },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, agent: agent, tenant: tenant, updated_at: rec["updated_at"] }
      end
    end
  end
end
