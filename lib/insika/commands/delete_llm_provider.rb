# frozen_string_literal: true

require "time"

module Insika
  module Commands
    # Control command: removes an LLM provider from the
    # LLMProviderStore. Idempotent (`existed: false` if there was none). UNDOES the
    # config in RubyLLM at runtime: when the provider existed, calls
    # `configurator.unapply(api)` clearing the global key/base — without a restart. A provider
    # that RubyLLM does not recognize degrades gracefully (unapply: false, nothing to
    # undo). -> { existed: bool }.
    class DeleteLLMProvider
      def initialize(provider_store:, configurator:, event_stream:)
        @provider_store = provider_store
        @configurator = configurator
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        api = AgentPayload.presence(p[:api])
        raise Insika::ValidationError, "api is required" if api.nil?

        existed = @provider_store.delete(api)
        @configurator.unapply(api) if existed
        @event_stream.emit(Insika::Event.new(
                             type: :llm_provider_deleted,
                             data: { api: api, existed: existed },
                             meta: { at: Time.now.utc.iso8601 }
                           ))
        { existed: existed }
      end
    end
  end
end
