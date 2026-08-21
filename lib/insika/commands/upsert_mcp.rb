# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: creates/edits an MCP instance
    # (transport/command/url/enabled + `env` credentials) in the McpStore. The
    # credentials are sentinel-aware per key (__OCULTO__ preserves; "" clears;
    # a new string replaces). Returns the MASKED record (env never comes back in
    # plaintext). Evicts any memoized client for this name (mcp_registry is
    # optional so a bare CLI/store-only caller need not wire one) so an edited
    # command/url/env takes effect on the instance's next call — no restart.
    class UpsertMcp
      def initialize(mcp_store:, event_stream:, mcp_registry: nil)
        @mcp_store = mcp_store
        @event_stream = event_stream
        @mcp_registry = mcp_registry
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        masked = @mcp_store.upsert(p) # validates `name`; returns masked
        @mcp_registry&.evict(masked["name"])

        @event_stream.emit(Insika::Event.new(
                             type: :mcp_upserted,
                             data: { name: masked["name"], enabled: masked["enabled"] },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        masked
      end
    end
  end
end
