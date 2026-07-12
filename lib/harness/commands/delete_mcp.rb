# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: remove uma instância MCP do
    # McpStore. Idempotente (`existed: false` se não havia). -> { existed: bool }.
    class DeleteMcp
      def initialize(mcp_store:, event_stream:)
        @mcp_store = mcp_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Harness::ValidationError, "name é obrigatório" if name.nil?

        existed = @mcp_store.delete(name)
        @event_stream.emit(Harness::Event.new(
                             type: :mcp_deleted,
                             data: { name: name, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
