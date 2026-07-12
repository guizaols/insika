# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa B): remove um agente. -> AgentProfile
    # removido (para o transporte confirmar o que sumiu). Turnos JÁ em andamento
    # que capturaram o profile seguem até terminar (o ProfileSource só afeta
    # novos dispatches).
    class DeleteAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        id = AgentPayload.presence(AgentPayload.symbolize(command.payload)[:id])
        raise Harness::ValidationError, "id é obrigatório" if id.nil?

        removed = @profile_source.fetch(id) ||
                  (raise Harness::NotFoundError, "agente '#{id}' não encontrado")

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
