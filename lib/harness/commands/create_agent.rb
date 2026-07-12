# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa B): cria um agente (AgentProfile) em
    # RUNTIME e persiste no ProfileSource (ConfigStore). É o "cada um cria sua
    # BIA". Síncrono; não cria Task. -> AgentProfile (round-tripado do store).
    class CreateAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        attrs = AgentPayload.attrs(command.payload)
        id = AgentPayload.presence(attrs[:id])
        raise Harness::ValidationError, "id é obrigatório" if id.nil?
        raise Harness::ValidationError, "model é obrigatório" if AgentPayload.presence(attrs[:model]).nil?
        raise Harness::ValidationError, "agente '#{id}' já existe" if @profile_source.fetch(id)

        @profile_source.put(Harness::AgentProfile.build(**attrs))
        emit(:agent_created, id)
        @profile_source.fetch(id) # devolve o profile persistido (symbols já normalizados)
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
