# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de CONTROLE (Fase 4 Etapa D / D6): cria/edita um provider de LLM
    # (api/base_url/auth_header/api_key/models) no LLMProviderStore e RECONFIGURA
    # o RubyLLM em runtime (LLMConfigurator) — troca de chave/base sem restart.
    # A `api_key` é sentinel-aware (__OCULTO__ preserva; "" limpa; string nova
    # substitui). Retorna o record MASCARADO (a chave nunca volta em plaintext).
    class UpsertLLMProvider
      def initialize(provider_store:, configurator:, event_stream:)
        @provider_store = provider_store
        @configurator = configurator
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        masked = @provider_store.upsert(p) # valida `api`; devolve mascarado

        # Reconfigura só ESTE provider (com a chave real do store, já reconciliada).
        result = @configurator.apply([@provider_store.get_raw(masked["api"])])
        @event_stream.emit(Harness::Event.new(
                             type: :llm_provider_upserted,
                             data: { api: masked["api"], applied: result[:applied], skipped: result[:skipped] },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        masked
      end
    end
  end
end
