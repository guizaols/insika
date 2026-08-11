# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Writes (upserts) a DATA-defined tool into the ToolStore and RELOADS the overlay +
    # catalog — takes effect without a restart. Rejects a name that collides with a
    # code tool (R3). Validating the definition (format, method/url, types,
    # placeholders) is the ToolStore/ToolDefinition's job. Secrets (headers) reconcile
    # in the store; the event carries only the name (0 leakage). -> { name, definition }.
    class WriteDataTool
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
        raise Insika::ValidationError, "'#{name}' is already a code tool" if @registry.code_tool?(name)

        masked = @tool_store.write(p, create_only: !!p[:create_only])
        @registry.reload
        @tool_catalog.reload
        emit(name)
        { name: name, definition: masked }
      end

      private

      def emit(name)
        @event_stream.emit(Insika::Event.new(
                             type: :data_tool_written, data: { name: name },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end
    end
  end
end
