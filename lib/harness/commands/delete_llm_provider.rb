# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: remove um provider de LLM do
    # LLMProviderStore. Idempotente (`existed: false` se não havia). NÃO
    # des-configura o RubyLLM em runtime — a config global de um provider já
    # aplicada persiste até o restart (degrada pra "restart recomendado", como o
    # OpenClaw); o que some é a fonte durável. -> { existed: bool }.
    class DeleteLLMProvider
      def initialize(provider_store:, event_stream:)
        @provider_store = provider_store
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        api = AgentPayload.presence(p[:api])
        raise Harness::ValidationError, "api é obrigatório" if api.nil?

        existed = @provider_store.delete(api)
        @event_stream.emit(Harness::Event.new(
                             type: :llm_provider_deleted,
                             data: { api: api, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
