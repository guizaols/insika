# frozen_string_literal: true

require "time"
require "yaml"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa C): grava uma skill compartilhada
    # (SKILL.md completo) no SkillStore e RECARREGA o catálogo — passa a valer
    # sem restart (hot). Valida o frontmatter (name obrigatório) antes de gravar.
    # -> { name, updated_at }.
    class WriteSkill
      def initialize(skill_store:, skill_catalog:, event_stream:)
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        content = p[:content].to_s
        raise Harness::ValidationError, "name é obrigatório" if name.nil?
        validate_frontmatter!(content)

        rec = @skill_store.write(name, content, create_only: !!p[:create_only])
        @skill_catalog.reload
        @event_stream.emit(Harness::Event.new(
                             type: :skill_written, data: { name: name },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, updated_at: rec["updated_at"] }
      end

      private

      # Espelha o parse do SkillCatalog: sem frontmatter YAML com `name`, a skill
      # seria ignorada silenciosamente no reload — falha cedo, no Command.
      def validate_frontmatter!(content)
        match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
        raise Harness::ValidationError, "SKILL.md sem frontmatter YAML (--- ... ---)" unless match

        meta = YAML.safe_load(match[1]) || {}
        raise Harness::ValidationError, "frontmatter sem `name`" if AgentPayload.presence(meta["name"]).nil?
      end
    end
  end
end
