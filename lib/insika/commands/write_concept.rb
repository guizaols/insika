# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: writes a concept (complete concept markdown) into the
    # KnowledgeStore. Validates the frontmatter (a `name` is required) before
    # writing — same discipline as `WriteSkill`. The STORE POSITION (the
    # `agent`/`name`/`tenant` triple) is the identity, exactly like a skill:
    # an operator editing the raw markdown may leave the frontmatter `name:`
    # unchanged even while promoting `provenance: observed` to `policy` —
    # that promotion IS this command, no separate "promote" action needed.
    # -> { name, agent, tenant, updated_at }.
    class WriteConcept
      def initialize(knowledge_store:, event_stream:)
        @knowledge_store = knowledge_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        agent = AgentPayload.presence(p[:agent])
        tenant = AgentPayload.presence(p[:tenant])
        content = p[:content].to_s
        raise Insika::ValidationError, "name is required" if name.nil?
        raise Insika::ValidationError, "agent is required" if agent.nil?

        parsed = validate_frontmatter!(content)
        rec = @knowledge_store.write(agent, name, content, tenant: tenant)
        emit(parsed[:type], name, agent)
        { name: name, agent: agent, tenant: tenant, updated_at: rec["updated_at"] }
      end

      private

      def emit(type, name, agent)
        @event_stream.emit(Insika::Event.new(
                             type: :knowledge_learned, data: { name: name, type: type, agent: agent },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      # Mirrors WriteSkill's frontmatter guard: without a parseable `name`,
      # the concept would be unreachable by name once written (the Studio
      # list keys on the store position, but the editor round-trips the
      # content) — fail early, in the Command.
      def validate_frontmatter!(content)
        parsed = Insika::Knowledge::Concept.parse(content)
        raise Insika::ValidationError, "concept missing YAML frontmatter (--- ... ---) or a `name`" if parsed.nil?

        parsed
      end
    end
  end
end
