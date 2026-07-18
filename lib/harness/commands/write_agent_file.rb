# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: writes an agent's prompt file to the
    # workspace (AgentFileStore). This is what gives each BIA its own identity — the
    # Prompt provider reads these files via `profile.prompt_files`. Takes effect
    # on the next dispatch (hot). -> { agent_id, file, updated_at }.
    class WriteAgentFile
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
        profile = @profile_source.fetch(agent_id) ||
                  (raise Harness::NotFoundError, "agent '#{agent_id}' not found")

        entry = @agent_files.write(agent_id, file, p[:content].to_s, create_only: !!p[:create_only])
        # Writing a prompt registers it in prompt_files — otherwise the Prompt provider
        # would never load it. It's the Command's job, not the dispatcher's.
        register_prompt_file(profile, file)
        emit(:agent_file_written, agent_id, file)
        { agent_id: agent_id, file: file, updated_at: entry["updated_at"] }
      end

      private

      def register_prompt_file(profile, file)
        files = Array(profile.prompt_files).map(&:to_s)
        return if files.include?(file)

        @profile_source.put(Harness::AgentProfile.build(**profile.to_h.merge(prompt_files: files + [file])))
      end

      def emit(type, agent_id, file)
        @event_stream.emit(Harness::Event.new(
                             type: type, data: { agent_id: agent_id, file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
