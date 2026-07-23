# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: restores an old version of a
    # prompt file as the current content (a new write — history is
    # linear, no rewinding). `version` = index into `versions` (0 = most recent
    # old one). -> { agent_id, file, updated_at }.
    class RestoreAgentFile
      def initialize(profile_source:, agent_file_store:, event_stream:)
        @profile_source = profile_source
        @agent_files = agent_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent_id = AgentPayload.presence(p[:agent_id])
        file = AgentPayload.presence(p[:file])
        raise Insika::ValidationError, "agent_id is required" if agent_id.nil?
        raise Insika::ValidationError, "file is required" if file.nil?
        raise Insika::ValidationError, "version is required" if p[:version].nil?

        entry = @agent_files.restore(agent_id, file, p[:version])
        @event_stream.emit(Insika::Event.new(
                             type: :agent_file_restored,
                             data: { agent_id: agent_id, file: file, version: Integer(p[:version]) },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { agent_id: agent_id, file: file, updated_at: entry["updated_at"] }
      end
    end
  end
end
