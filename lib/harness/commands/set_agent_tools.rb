# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa B / D4): ajusta a allow/denylist de tools
    # de um agente. `allow` nil = todas (regra do AgentProfile); `deny` sempre
    # vence. Vale no próximo dispatch (hot). -> AgentProfile.
    class SetAgentTools
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        id = AgentPayload.presence(p[:id])
        raise Harness::ValidationError, "id é obrigatório" if id.nil?
        raise Harness::ValidationError, "allow deve ser lista ou nulo" unless p[:allow].nil? || p[:allow].is_a?(Array)

        existing = @profile_source.fetch(id) ||
                   (raise Harness::NotFoundError, "agente '#{id}' não encontrado")

        merged = existing.to_h.merge(tools_allow: p[:allow], tools_deny: Array(p[:deny]))
        @profile_source.put(Harness::AgentProfile.build(**merged))
        @event_stream.emit(Harness::Event.new(
                             type: :agent_tools_set, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        @profile_source.fetch(id)
      end
    end
  end
end
