# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: removes an authored skill from the SkillStore and RELOADS the
    # catalog. -> { name, agent, deleted }.
    #
    # With `agent`, it deletes only that agent's SPECIALIZATION — the shared skill
    # stays exactly where it was, and the agent falls back to it on the next turn.
    # "Stop specializing this" is the inverse of the specialize action, and it must not
    # be expressible as "delete the skill".
    #
    # Deleting a shared skill does NOT touch any allowlist: an agent left naming a
    # skill that no longer exists sees nothing (the catalog resolves nothing), which is
    # the same outcome as never having allowed it.
    class DeleteSkill
      def initialize(skill_store:, skill_catalog:, event_stream:)
        @skill_store = skill_store
        @skill_catalog = skill_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        agent = AgentPayload.presence(p[:agent])
        raise Insika::ValidationError, "name is required" if name.nil?

        deleted = @skill_store.delete(name, agent: agent)
        raise Insika::NotFoundError, "skill '#{name}' not found#{" for agent '#{agent}'" if agent}" unless deleted

        @skill_catalog.reload
        @event_stream.emit(Insika::Event.new(
                             type: :skill_deleted, data: { name: name, agent: agent }.compact,
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, agent: agent, deleted: true }
      end
    end
  end
end
