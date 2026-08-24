# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: removes a learned concept from the KnowledgeStore.
    # -> { name, agent, tenant, deleted: true }.
    class DeleteConcept
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

        deleted = @knowledge_store.delete(agent, name, tenant: tenant)
        raise Insika::NotFoundError, "concept '#{name}' not found for agent '#{agent}'" unless deleted

        @event_stream.emit(Insika::Event.new(
                             type: :knowledge_deleted, data: { name: name, agent: agent },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, agent: agent, tenant: tenant, deleted: true }
      end
    end
  end
end
