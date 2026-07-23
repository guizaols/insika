# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Restores an old version of a data tool (a new write) and reloads
    # overlay + catalog. The ToolStore raises NotFound/Validation. -> { name,
    # definition (masked) }.
    class RestoreDataTool
      def initialize(tool_store:, registry:, tool_catalog:, event_stream:)
        @tool_store = tool_store
        @registry = registry
        @tool_catalog = tool_catalog
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Insika::ValidationError, "name is required" if name.nil?

        masked = @tool_store.restore(name, p[:index])
        @registry.reload
        @tool_catalog.reload
        @event_stream.emit(Insika::Event.new(
                             type: :data_tool_restored, data: { name: name },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { name: name, definition: masked }
      end
    end
  end
end
