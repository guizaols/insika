# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: LIVE MCP ingestion (Phase 7, Step E). Receives the NAME of
    # an MCP instance, delegates to McpToolIngestor (discovers via an injectable client
    # -> builds the manifest -> reuses :import_tools: batch upsert + hot reload)
    # and returns the per-tool report in the shape of :import_tools, plus
    # `instance:`. Idempotent (re-ingesting reconciles). A per-tool failure is isolated
    # in `errors[]` (R4); an absent/disabled/url-less instance raises.
    #   -> { instance, version, created: [names], updated: [names], errors: [{tool,error}] }
    class ImportMcpTools
      def initialize(ingestor:, event_stream:)
        @ingestor = ingestor
        @event_stream = event_stream
      end

      def call(command)
        p = symbolize(command.payload)
        name = Harness::Coercion.presence(p[:name]) ||
               (raise Harness::ValidationError, "import_mcp_tools: 'name' (MCP instance) is required")

        report = @ingestor.ingest(name)
        emit(report)
        report
      end

      private

      # Emits only COUNTS + the instance name (never headers/env/secrets): 0 leakage.
      def emit(report)
        @event_stream.emit(Harness::Event.new(
                             type: :mcp_tools_imported,
                             data: { instance: report[:instance],
                                     created: report[:created].size, updated: report[:updated].size,
                                     errors: report[:errors].size },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
      end

      def symbolize(payload)
        (payload || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end
    end
  end
end
