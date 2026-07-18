# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: removes a prompt file from an agent's
    # workspace. Nonexistent -> NotFoundError. -> { agent_id, file }.
    class DeleteAgentFile
      def initialize(profile_source:, agent_file_store:, event_stream:)
        @profile_source = profile_source
        @agent_files = agent_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        agent_id = AgentPayload.presence(p[:agent_id])
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "agent_id is required" if agent_id.nil?
        raise Harness::ValidationError, "file is required" if file.nil?

        unless @agent_files.delete(agent_id, file)
          raise Harness::NotFoundError, "file '#{file}' not found for agent '#{agent_id}'"
        end

        unregister_prompt_file(agent_id, file)
        @event_stream.emit(Harness::Event.new(
                             type: :agent_file_deleted, data: { agent_id: agent_id, file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { agent_id: agent_id, file: file }
      end

      private

      # Removing the file also drops it from prompt_files (the inverse operation of
      # WriteAgentFile) — the Command's job, not the dispatcher's.
      def unregister_prompt_file(agent_id, file)
        profile = @profile_source.fetch(agent_id)
        return unless profile

        files = Array(profile.prompt_files).map(&:to_s)
        return unless files.include?(file)

        @profile_source.put(Harness::AgentProfile.build(**profile.to_h.merge(prompt_files: files - [file])))
      end
    end
  end
end
