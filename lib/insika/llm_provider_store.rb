# frozen_string_literal: true

module Insika
  # LLM providers authored at runtime. One record per
  # provider in the ConfigStore (scope "llm_providers"), keyed by the API slug
  # (`deepseek`, `openai`, ...). Holds base_url/auth_header/models and the `api_key`.
  #
  # The `api_key` NEVER leaves here in plaintext to the UI: the display reads
  # (`get`/`all`) mask it with the `__OCULTO__` sentinel. Only `all_raw`/`get_raw`
  # (consumed by the LLMConfigurator, never by the screen) return the real key.
  # On write, the sentinel coming back preserves the key; a new string replaces it; ""
  # clears it (see Insika::SecretMasking).
  class LLMProviderStore
    include Coercion

    SCOPE = "llm_providers"

    def initialize(config_store:)
      @cs = config_store
    end

    # -> MASKED Hash | nil.
    def get(api)
      mask(raw(api))
    end

    # -> Hash with REAL api_key | nil. Internal use (LLMConfigurator).
    def get_raw(api)
      raw(api)
    end

    # -> [String] slugs, lexicographic order.
    def apis = @cs.keys(SCOPE)

    # -> [Hash] all MASKED (for the UI).
    def all
      apis.filter_map { |a| get(a) }
    end

    # -> [Hash] all with REAL api_key (for the configurator). Never goes to the screen.
    def all_raw
      apis.filter_map { |a| raw(a) }
    end

    # Upsert with secret reconciliation. `attrs` (string|symbol keys):
    #   api (required), base_url, auth_header, api_key (sentinel-aware), models[]
    # -> MASKED Hash (the stored record).
    def upsert(attrs)
      h = symbolize(attrs)
      api = presence(h[:api])
      raise Insika::ValidationError, "api is required" if api.nil?

      existing = raw(api)
      record = {
        "api" => api,
        "base_url" => presence(h[:base_url]),
        "auth_header" => presence(h[:auth_header]),
        "api_key" => SecretMasking.reconcile(h[:api_key], existing&.fetch("api_key", nil)),
        "models" => Array(h[:models]).map(&:to_s)
      }
      @cs.put(SCOPE, api, record)
      mask(record)
    end

    # -> bool (did it exist?).
    def delete(api) = @cs.delete(SCOPE, api.to_s)

    private

    def raw(api) = @cs.get(SCOPE, api.to_s)

    # Swaps the real api_key for the sentinel (or nil if absent) — never leaks plaintext.
    def mask(record)
      return nil if record.nil?

      record.merge("api_key" => SecretMasking.mask(record["api_key"]))
    end

    def symbolize(attrs)
      (attrs || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end
