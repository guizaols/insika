# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: remove um arquivo de prompt do
    # workspace de um agente. Inexistente -> NotFoundError. -> { agent_id, file }.
    class DeleteAgentFile
      def initialize(profile_source:, agent_file_store:, event_stream:)
        @profile_source = profile_source
        @agent_files = agent_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent_id = AgentPayload.presence(p[:agent_id])
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "agent_id é obrigatório" if agent_id.nil?
        raise Harness::ValidationError, "file é obrigatório" if file.nil?

        unless @agent_files.delete(agent_id, file)
          raise Harness::NotFoundError, "arquivo '#{file}' não encontrado para o agente '#{agent_id}'"
        end

        @event_stream.emit(Harness::Event.new(
                             type: :agent_file_deleted, data: { agent_id: agent_id, file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { agent_id: agent_id, file: file }
      end
    end
  end
end
