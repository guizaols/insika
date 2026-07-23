# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: writes a GLOBAL system file into the
    # SystemFileStore. Unlike write_agent_file (per agent), these files
    # apply to ALL agents — the Prompt provider injects them before the
    # individual identity. Takes effect on the next turn (hot). -> { file, updated_at }.
    class WriteSystemFile
      def initialize(system_file_store:, event_stream:)
        @system_files = system_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        file = AgentPayload.presence(p[:file])
        raise Insika::ValidationError, "file is required" if file.nil?

        entry = @system_files.write(file, p[:content].to_s, create_only: !!p[:create_only])
        @event_stream.emit(Insika::Event.new(
                             type: :system_file_written, data: { file: file },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { file: file, updated_at: entry["updated_at"] }
      end
    end
  end
end
