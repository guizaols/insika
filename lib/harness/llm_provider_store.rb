# frozen_string_literal: true

module Harness
  # Providers de LLM autorados em runtime. Um record por
  # provider no ConfigStore (scope "llm_providers"), keyed pelo slug da API
  # (`deepseek`, `openai`, ...). Guarda base_url/auth_header/models e a `api_key`.
  #
  # A `api_key` NUNCA sai daqui em plaintext pra UI: as leituras de exibição
  # (`get`/`all`) mascaram com o sentinel `__OCULTO__`. Só `all_raw`/`get_raw`
  # (consumidos pelo LLMConfigurator, nunca pela tela) devolvem a chave real.
  # Na escrita, o sentinel de volta preserva a chave; string nova substitui; ""
  # limpa (ver Harness::SecretMasking).
  class LLMProviderStore
    SCOPE = "llm_providers"

    def initialize(config_store:)
      @cs = config_store
    end

    # -> Hash MASCARADO | nil.
    def get(api)
      mask(raw(api))
    end

    # -> Hash com api_key REAL | nil. Uso interno (LLMConfigurator).
    def get_raw(api)
      raw(api)
    end

    # -> [String] slugs, ordem lexicográfica.
    def apis = @cs.keys(SCOPE)

    # -> [Hash] todos MASCARADOS (pra UI).
    def all
      apis.filter_map { |a| get(a) }
    end

    # -> [Hash] todos com api_key REAL (pro configurator). Nunca vai pra tela.
    def all_raw
      apis.filter_map { |a| raw(a) }
    end

    # Upsert com reconciliação de segredo. `attrs` (string|symbol keys):
    #   api (obrigatório), base_url, auth_header, api_key (sentinel-aware), models[]
    # -> Hash MASCARADO (record gravado).
    def upsert(attrs)
      h = symbolize(attrs)
      api = presence(h[:api])
      raise Harness::ValidationError, "api é obrigatório" if api.nil?

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

    # -> bool (existia?).
    def delete(api) = @cs.delete(SCOPE, api.to_s)

    private

    def raw(api) = @cs.get(SCOPE, api.to_s)

    # Troca a api_key real pelo sentinel (ou nil se ausente) — nunca vaza plaintext.
    def mask(record)
      return nil if record.nil?

      record.merge("api_key" => SecretMasking.mask(record["api_key"]))
    end

    def symbolize(attrs)
      (attrs || {}).each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    def presence(str) = str.nil? || str.to_s.empty? ? nil : str.to_s
  end
end
