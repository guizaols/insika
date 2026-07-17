# frozen_string_literal: true

require "time"
require "yaml"

module Harness
  module Commands
    # Control command: writes a shared skill
    # (complete SKILL.md) into the SkillStore and RELOADS the catalog — takes effect
    # without a restart (hot). Validates the frontmatter (name required) before writing.
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
        raise Harness::ValidationError, "name is required" if name.nil?
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

      # Mirrors the SkillCatalog parse: without YAML frontmatter with `name`, the skill
      # would be silently ignored on reload — fail early, in the Command.
      def validate_frontmatter!(content)
        match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
        raise Harness::ValidationError, "SKILL.md missing YAML frontmatter (--- ... ---)" unless match

        # Tolerant parser (Frontmatter): prose with `: ` in the description is valid —
        # it must not become a Psych::SyntaxError (500). Only fails if `name` is missing.
        meta = Harness::Frontmatter.parse(match[1])
        raise Harness::ValidationError, "frontmatter missing `name`" if AgentPayload.presence(meta["name"]).nil?
      end
    end
  end
end
