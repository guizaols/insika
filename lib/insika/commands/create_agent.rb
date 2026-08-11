# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: creates an agent (AgentProfile) at
    # RUNTIME and persists it in the ProfileSource (ConfigStore). This is the "everyone creates
    # their own BIA". Synchronous; does not create a Task. -> AgentProfile (round-tripped from the store).
    class CreateAgent
      def initialize(profile_source:, event_stream:)
        @profile_source = profile_source
        @event_stream = event_stream
      end

      def call(command)
        attrs = AgentPayload.attrs(command.payload)
        id = AgentPayload.presence(attrs[:id])
        raise Insika::ValidationError, "id is required" if id.nil?
        # model is OPTIONAL as of v2: omitted -> resolves the platform
        # default_model (Settings) at turn start. An agent with neither its own
        # model nor a platform default fails clearly at the first turn.
        raise Insika::ValidationError, "agent '#{id}' already exists" if @profile_source.fetch(id)

        profile = Insika::AgentProfile.build(**attrs)
        # definition-time cycle + depth check. Only a profile that
        # introduces edges (non-empty subagents) can create a violation — a
        # childless agent is always a safe leaf. Raises SubagentError (a
        # ValidationError) BEFORE persisting, so a bad graph never lands.
        validate_subagent_graph!(profile)
        @profile_source.put(profile)
        emit(:agent_created, id)
        @profile_source.fetch(id) # returns the persisted profile (symbols already normalized)
      end

      private

      # Validates the delegation graph with `profile` added to the current set.
      def validate_subagent_graph!(profile)
        return if Array(profile.subagents).empty?

        others = @profile_source.all.reject { |p| p.id.to_s == profile.id.to_s }
        Insika::SubagentGraph.validate!(others + [profile])
      end

      def emit(type, id)
        @event_stream.emit(Insika::Event.new(
                             type: type, data: { agent_id: id },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
