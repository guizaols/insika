# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: removes a global system file
    # from the SystemFileStore. Idempotent (`existed: false`). -> { existed: bool }.
    class DeleteSystemFile
      def initialize(system_file_store:, event_stream:)
        @system_files = system_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "file is required" if file.nil?

        existed = @system_files.delete(file)
        @event_stream.emit(Harness::Event.new(
                             type: :system_file_deleted, data: { file: file, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
