# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa C): restaura uma versão antiga de um
    # arquivo de prompt como o conteúdo atual (nova escrita — o histórico é
    # linear, sem rebobinar). `version` = índice em `versions` (0 = mais recente
    # antiga). -> { agent_id, file, updated_at }.
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
        raise Harness::ValidationError, "agent_id é obrigatório" if agent_id.nil?
        raise Harness::ValidationError, "file é obrigatório" if file.nil?
        raise Harness::ValidationError, "version é obrigatório" if p[:version].nil?

        entry = @agent_files.restore(agent_id, file, p[:version])
        @event_stream.emit(Harness::Event.new(
                             type: :agent_file_restored,
                             data: { agent_id: agent_id, file: file, version: Integer(p[:version]) },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { agent_id: agent_id, file: file, updated_at: entry["updated_at"] }
      end
    end
  end
end
