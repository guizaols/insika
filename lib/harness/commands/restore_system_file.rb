# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: restores an old version of a
    # global system file as the current content (a new write — linear
    # history). -> { file, updated_at }.
    class RestoreSystemFile
      def initialize(system_file_store:, event_stream:)
        @system_files = system_file_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        file = AgentPayload.presence(p[:file])
        raise Harness::ValidationError, "file is required" if file.nil?
        raise Harness::ValidationError, "version is required" if p[:version].nil?

        entry = @system_files.restore(file, p[:version])
        @event_stream.emit(Harness::Event.new(
                             type: :system_file_restored, data: { file: file, version: p[:version].to_s },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { file: file, updated_at: entry["updated_at"] }
      end
    end
  end
end
