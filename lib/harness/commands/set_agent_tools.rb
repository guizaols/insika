# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: adjusts an agent's tools allow/denylist.
    # `allow` nil = all (AgentProfile rule); `deny` always
    # wins. `allow_groups` (Phase 7/D4/F5, Step C): per-group allowlist, only
    # overwritten if the key comes in the payload (otherwise preserved). Takes effect on the next
    # dispatch (hot). -> AgentProfile.
    class SetAgentTools
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        id = AgentPayload.presence(p[:id])
        raise Harness::ValidationError, "id is required" if id.nil?
        raise Harness::ValidationError, "allow must be a list or nil" unless p[:allow].nil? || p[:allow].is_a?(Array)
        raise Harness::ValidationError, "allow_groups must be a list or nil" unless p[:allow_groups].nil? || p[:allow_groups].is_a?(Array)

        existing = @profile_source.fetch(id) ||
                   (raise Harness::NotFoundError, "agent '#{id}' not found")

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
