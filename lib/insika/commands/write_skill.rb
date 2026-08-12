# frozen_string_literal: true

require "time"
require "yaml"

module Insika
  module Commands
    # Control command: writes a skill (complete SKILL.md) into
    # the SkillStore and RELOADS the catalog — takes effect without a restart (hot).
    # Validates the frontmatter (name required) before writing. -> { name, agent, updated_at }.
    #
    # `agent` (optional) writes into that agent's scope instead of the shared one: the
    # SPECIALIZATION of a shared skill, or a skill private to one agent. Same `name`
    # either way — the store position is the identity, so the frontmatter inside an
    # override keeps saying the bare shared name and the level-1 catalog, load_skill,
    # the labels and the events all keep displaying it.
    class WriteSkill
      def initialize(skill_store:, skill_catalog:, event_stream:)
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        agent = AgentPayload.presence(p[:agent])
        content = p[:content].to_s
        raise Insika::ValidationError, "name is required" if name.nil?
        validate_frontmatter!(content)

        rec = @skill_store.write(name, content, agent: agent, create_only: !!p[:create_only])
        @skill_catalog.reload
        emit(:skill_written, name, agent)
        { name: name, agent: agent, updated_at: rec["updated_at"] }
      end

      private

      def emit(type, name, agent)
        @event_stream.emit(Insika::Event.new(
                             type: type, data: { name: name, agent: agent }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      # Mirrors the SkillCatalog parse: without YAML frontmatter with `name`, the skill
      # would be silently ignored on reload — fail early, in the Command.
      def validate_frontmatter!(content)
        match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
        raise Insika::ValidationError, "SKILL.md missing YAML frontmatter (--- ... ---)" unless match

        # Tolerant parser (Frontmatter): prose with `: ` in the description is valid —
        # it must not become a Psych::SyntaxError (500). Only fails if `name` is missing.
        meta = Insika::Frontmatter.parse(match[1])
        raise Insika::ValidationError, "frontmatter missing `name`" if AgentPayload.presence(meta["name"]).nil?
      end
    end
  end
end
