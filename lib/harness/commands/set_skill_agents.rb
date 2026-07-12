# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: habilita/desabilita uma skill em N
    # agentes de uma vez, mexendo na allowlist `profile.skills` de cada um.
    # Vale no próximo dispatch (hot via ProfileSource). -> { name, enabled_for }.
    #
    # Semântica da allowlist (AgentProfile): nil = TODAS, [] = nenhuma,
    # [names] = subconjunto. Consequência importante e deliberada:
    #  - habilitar num agente com skills=nil: no-op (já tem todas).
    #  - DESABILITAR num agente com skills=nil: NÃO é feito aqui — remover uma de
    #    "todas" exigiria enumerar o catálogo e materializar uma allowlist
    #    explícita (destrutivo/surpreendente). Estes agentes ficam intactos e
    #    entram em `skipped_all`. Para restringir, use :set_agent_tools/allowlist
    #    explícita primeiro.
    class SetSkillAgents
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Harness::ValidationError, "name é obrigatório" if name.nil?
        raise Harness::ValidationError, "agent_ids deve ser lista" unless p[:agent_ids].nil? || p[:agent_ids].is_a?(Array)

        wanted = Array(p[:agent_ids]).map(&:to_s)
        enabled_for = []
        skipped_all = []

        @profile_source.all.each do |profile|
          want = wanted.include?(profile.id)
          new_skills = next_skills(profile.skills, name, want)

          if new_skills == :skip
            skipped_all << profile.id
            next
          end
          next if new_skills == profile.skills # sem mudança

          @profile_source.put(Harness::AgentProfile.build(**profile.to_h.merge(skills: new_skills)))
          enabled_for << profile.id if want
        end

        @event_stream.emit(Harness::Event.new(
                             type: :skill_agents_set,
                             data: { name: name, agent_ids: wanted, skipped_all: skipped_all },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, enabled_for: enabled_for, skipped_all: skipped_all }
      end

      private

      # -> nova allowlist | :skip (agente com nil que pediu desabilitar).
      def next_skills(current, name, want)
        if want
          current.nil? ? nil : (Array(current).map(&:to_s) | [name])
        elsif current.nil?
          :skip
        else
          Array(current).map(&:to_s) - [name]
        end
      end
    end
  end
end
