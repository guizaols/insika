# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: removes an MCP instance from the
    # McpStore. Idempotent (`existed: false` if there was none). Evicts any
    # memoized client for this name — a removed instance stops answering
    # tool calls right away, not after a restart. -> { existed: bool }.
    class DeleteMcp
      def initialize(mcp_store:, event_stream:, mcp_registry: nil)
        @mcp_store = mcp_store
        @event_stream = event_stream
        @mcp_registry = mcp_registry
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        name = AgentPayload.presence(p[:name])
        raise Insika::ValidationError, "name is required" if name.nil?

        existed = @mcp_store.delete(name)
        @mcp_registry&.evict(name)
        @event_stream.emit(Insika::Event.new(
                             type: :mcp_deleted,
                             data: { name: name, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
