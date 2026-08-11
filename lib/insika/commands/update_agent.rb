# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: edits an existing agent. Merges the
    # patch over the current profile (only the sent fields change) + rebuild + put.
    # Takes effect on the NEXT dispatch (the ProfileSource reads fresh). -> AgentProfile.
    class UpdateAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        patch = AgentPayload.attrs(command.payload)
        id = AgentPayload.presence(patch[:id])
        raise Insika::ValidationError, "id is required" if id.nil?

        existing = @profile_source.fetch(id) ||
                   (raise Insika::NotFoundError, "agent '#{id}' not found")

        # to_h of the current profile brings the correct symbols; patch overwrites only
        # what was sent. id never changes (rename = create+delete, out of scope).
        merged = existing.to_h.merge(patch).merge(id: id)
        profile = Insika::AgentProfile.build(**merged)
        # definition-time cycle + depth check (an update may ADD
        # subagents to an existing agent). Raises SubagentError before persisting.
        validate_subagent_graph!(profile)
        @profile_source.put(profile)
        @event_stream.emit(Insika::Event.new(
                             type: :agent_updated, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        @profile_source.fetch(id)
      end

      private

      def validate_subagent_graph!(profile)
        return if Array(profile.subagents).empty?

        others = @profile_source.all.reject { |p| p.id.to_s == profile.id.to_s }
        Insika::SubagentGraph.validate!(others + [profile])
      end
    end
  end
end
