# frozen_string_literal: true

require "time"

module Harness
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
        raise Harness::ValidationError, "id is required" if id.nil?

        existing = @profile_source.fetch(id) ||
                   (raise Harness::NotFoundError, "agent '#{id}' not found")

        # to_h of the current profile brings the correct symbols; patch overwrites only
        # what was sent. id never changes (rename = create+delete, out of scope).
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
