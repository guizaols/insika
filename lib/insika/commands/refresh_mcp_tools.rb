# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: LIVE re-discovery of an MCP instance's tools
    # (RFC-0040 PR2). Delegates to McpToolRegistry#refresh (connect +
    # tools/list + write McpStore#tools_cache) — TOOL EXECUTION never reads
    # that cache; this command only refreshes what `entries`/Studio/doctor
    # display. The CLI verb / API route / Studio button that call it are
    # later work (PR3/PR4) — the command itself is the seam they'll share.
    # -> { instance:, tools: [{name,description,inputSchema}, ...] }.
    class RefreshMcpTools
      def initialize(mcp_registry:, event_stream:)
        @mcp_registry = mcp_registry
        @event_stream = event_stream
      end

      def call(command)
        p = symbolize(command.payload)
        name = Insika::Coercion.presence(p[:name]) ||
               (raise Insika::ValidationError, "refresh_mcp_tools: 'name' (MCP instance) is required")

        tools = @mcp_registry.refresh(name)
        emit(name, tools)
        { instance: name, tools: tools }
      end

      private

      # Emits only the COUNT + the instance name (never a tool's schema, in
      # case a schema description ever carries something sensitive): 0 leakage.
      def emit(name, tools)
        @event_stream.emit(Insika::Event.new(
                             type: :mcp_tools_refreshed,
                             data: { instance: name, tools: tools.size },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      def symbolize(payload)
        (payload || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end
  end
end
