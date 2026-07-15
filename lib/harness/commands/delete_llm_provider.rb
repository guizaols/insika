# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Command de controle: remove um provider de LLM do
    # LLMProviderStore. Idempotente (`existed: false` se não havia). DESFAZ a
    # config no RubyLLM em runtime (§9.5): quando o provider existia, chama
    # `configurator.unapply(api)` zerando key/base globais — sem restart. Provider
    # que o RubyLLM não reconhece degrada naturalmente (unapply: false, nada a
    # desfazer). -> { existed: bool }.
    class DeleteLLMProvider
      def initialize(provider_store:, configurator:, event_stream:)
        @provider_store = provider_store
        @configurator = configurator
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        api = AgentPayload.presence(p[:api])
        raise Harness::ValidationError, "api é obrigatório" if api.nil?

        existed = @provider_store.delete(api)
        @configurator.unapply(api) if existed
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
