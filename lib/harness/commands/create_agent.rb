# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: creates an agent (AgentProfile) at
    # RUNTIME and persists it in the ProfileSource (ConfigStore). This is the "everyone creates
    # their own BIA". Synchronous; does not create a Task. -> AgentProfile (round-tripped from the store).
    class CreateAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        attrs = AgentPayload.attrs(command.payload)
        id = AgentPayload.presence(attrs[:id])
        raise Harness::ValidationError, "id is required" if id.nil?
        raise Harness::ValidationError, "model is required" if AgentPayload.presence(attrs[:model]).nil?
        raise Harness::ValidationError, "agente '#{id}' já existe" if @profile_source.fetch(id)

        @profile_source.put(Harness::AgentProfile.build(**attrs))
        emit(:agent_created, id)
        @profile_source.fetch(id) # returns the persisted profile (symbols already normalized)
      end

      private

      def emit(type, id)
        @event_stream.emit(Harness::Event.new(
                             type: type, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
