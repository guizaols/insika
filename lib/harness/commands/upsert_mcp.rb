# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa G / D6): cria/edita uma instância MCP
    # (transport/command/url/enabled + credenciais `env`) no McpStore. As
    # credenciais são sentinel-aware por chave (__OCULTO__ preserva; "" limpa;
    # string nova substitui). Retorna o record MASCARADO (env nunca volta em
    # plaintext). CRUD de config durável — a execução de um cliente MCP contra a
    # instância é runtime posterior (spec, open questions).
    class UpsertMcp
      def initialize(mcp_store:, event_stream:)
        @mcp_store = mcp_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        masked = @mcp_store.upsert(p) # valida `name`; devolve mascarado

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
