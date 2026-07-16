# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: ajusta a allow/denylist de tools
    # de um agente. `allow` nil = todas (regra do AgentProfile); `deny` sempre
    # vence. `allow_groups` (Fase 7/D4/F5, Etapa C): allowlist por grupo, só
    # sobrescrita se a chave vier no payload (senão preserva). Vale no próximo
    # dispatch (hot). -> AgentProfile.
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
        raise Harness::ValidationError, "allow_groups deve ser lista ou nulo" unless p[:allow_groups].nil? || p[:allow_groups].is_a?(Array)

        existing = @profile_source.fetch(id) ||
                   (raise Harness::NotFoundError, "agente '#{id}' não encontrado")

        merged = existing.to_h.merge(tools_allow: p[:allow], tools_deny: Array(p[:deny]))
        merged[:tools_allow_groups] = p[:allow_groups] if p.key?(:allow_groups)
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
