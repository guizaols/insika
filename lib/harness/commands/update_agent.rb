# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa B): edita um agente existente. Merge do
    # patch sobre o profile atual (só os campos enviados mudam) + rebuild + put.
    # Vale no PRÓXIMO dispatch (o ProfileSource lê fresco). -> AgentProfile.
    class UpdateAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        patch = AgentPayload.attrs(command.payload)
        id = AgentPayload.presence(patch[:id])
        raise Harness::ValidationError, "id é obrigatório" if id.nil?

        existing = @profile_source.fetch(id) ||
                   (raise Harness::NotFoundError, "agente '#{id}' não encontrado")

        # to_h do profile atual traz os symbols corretos; patch sobrescreve só o
        # enviado. id nunca muda (rename = create+delete, fora de escopo).
        merged = existing.to_h.merge(patch).merge(id: id)
        @profile_source.put(Harness::AgentProfile.build(**merged))
        @event_stream.emit(Harness::Event.new(
                             type: :agent_updated, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        @profile_source.fetch(id)
      end
    end
  end
end
