# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: creates/edits an MCP instance
    # (transport/command/url/enabled + `env` credentials) in the McpStore. The
    # credentials are sentinel-aware per key (__OCULTO__ preserves; "" clears;
    # a new string replaces). Returns the MASKED record (env never comes back in
    # plaintext). Durable config CRUD — running an MCP client against the
    # instance is later runtime.
    class UpsertMcp
      def initialize(mcp_store:, event_stream:)
        @mcp_store = mcp_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        masked = @mcp_store.upsert(p) # validates `name`; returns masked

        @event_stream.emit(Harness::Event.new(
                             type: :mcp_upserted,
                             data: { name: masked["name"], enabled: masked["enabled"] },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        masked
      end
    end
  end
end
