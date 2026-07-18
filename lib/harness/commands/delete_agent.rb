# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: removes an agent. -> the removed AgentProfile
    # (so the transport can confirm what disappeared). Turns ALREADY in progress
    # that captured the profile keep going until they finish (the ProfileSource only affects
    # new dispatches).
    class DeleteAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        id = AgentPayload.presence(AgentPayload.symbolize(command.payload)[:id])
        raise Harness::ValidationError, "id is required" if id.nil?

        removed = @profile_source.fetch(id) ||
                  (raise Harness::NotFoundError, "agent '#{id}' not found")

        @profile_source.delete(id)
        @event_stream.emit(Harness::Event.new(
                             type: :agent_deleted, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        removed
      end
    end
  end
end
