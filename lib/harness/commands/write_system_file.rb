# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa G): grava um arquivo de sistema GLOBAL no
    # SystemFileStore. Diferente do write_agent_file (por agente), estes arquivos
    # valem para TODOS os agentes — o Prompt provider os injeta antes da
    # identidade individual. Vale no próximo turno (hot). -> { file, updated_at }.
    class WriteSystemFile
      def initialize(system_file_store:, event_stream:)
        @system_files = system_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "file é obrigatório" if file.nil?

        entry = @system_files.write(file, p[:content].to_s, create_only: !!p[:create_only])
        @event_stream.emit(Harness::Event.new(
                             type: :system_file_written, data: { file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { file: file, updated_at: entry["updated_at"] }
      end
    end
  end
end
