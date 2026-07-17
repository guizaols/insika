# frozen_string_literal: true

require "time"

module Harness
  module Commands
    # Control command: creates/edits an LLM provider
    # (api/base_url/auth_header/api_key/models) in the LLMProviderStore and RECONFIGURES
    # RubyLLM at runtime (LLMConfigurator) — swaps key/base without a restart.
    # The `api_key` is sentinel-aware (__OCULTO__ preserves; "" clears; a new string
    # replaces). Returns the MASKED record (the key never comes back in plaintext).
    class UpsertLLMProvider
      def initialize(provider_store:, configurator:, event_stream:)
        @provider_store = provider_store
        @configurator = configurator
        @event_stream = event_stream
      end

      def call(command)
        p = AgentPayload.symbolize(command.payload)
        masked = @provider_store.upsert(p) # validates `api`; returns masked

        # Reconfigures only THIS provider (with the real key from the store, already reconciled).
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
