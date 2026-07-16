# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: ingestão MCP LIVE (Fase 7, Etapa E). Recebe o NOME de
    # uma instância MCP, delega ao McpToolIngestor (descobre via cliente injetável
    # -> constrói o manifesto -> reusa o :import_tools: upsert em lote + reload hot)
    # e devolve o relatório por-tool no molde do :import_tools, acrescido de
    # `instance:`. Idempotente (re-ingerir reconcilia). Falha por-tool fica isolada
    # em `errors[]` (R4); instância ausente/desabilitada/sem-url levanta.
    #   -> { instance, version, created: [names], updated: [names], errors: [{tool,error}] }
    class ImportMcpTools
      def initialize(ingestor:, event_stream:)
        @ingestor = ingestor
        @event_stream = event_stream
      end

      def call(command)
        p = symbolize(command.payload)
        name = Harness::Coercion.presence(p[:name]) ||
               (raise Harness::ValidationError, "import_mcp_tools: 'name' (instância MCP) é obrigatório")

        report = @ingestor.ingest(name)
        emit(report)
        report
      end

      private

      # Emite só CONTAGENS + nome da instância (nunca headers/env/secrets): 0 vazamento.
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
