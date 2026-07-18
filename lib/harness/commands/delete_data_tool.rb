# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Removes a data tool from the ToolStore and reloads overlay + catalog.
    # 404 if it did not exist. -> { name }.
    class DeleteDataTool
      def initialize(tool_store:, registry:, tool_catalog:, event_stream:)
        @tool_store = tool_store
        @registry = registry
        @tool_catalog = tool_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Harness::ValidationError, "name is required" if name.nil?
        raise Harness::NotFoundError, "tool '#{name}' not found" unless @tool_store.delete(name)

        @registry.reload
        @tool_catalog.reload
        @event_stream.emit(Harness::Event.new(
                             type: :data_tool_deleted, data: { name: name },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name }
      end
    end
  end
end
