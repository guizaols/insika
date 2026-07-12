# frozen_string_literal: true

module Harness
  # Aplica os providers de LLM autorados (LLMProviderStore) no RubyLLM em RUNTIME
  # (Fase 4 — Studio, D6). Meta: trocar chave/base de um provider SEM restart —
  # o RubyLLM expõe `config.<api>_api_key=` / `config.<api>_api_base=`, então
  # reconfigurar é setar esses acessores por provider.
  #
  # Restrição D9 do core: este arquivo NÃO requer ruby_llm em load-time — o
  # `require` é lazy, dentro de `apply` (e injetável via `configure:` pra teste,
  # que roda sem a gem/chave). Um provider que o RubyLLM não reconhece (sem
  # acessor correspondente) NÃO explode: entra em `skipped` (degrada pra "restart
  # recomendado", como o OpenClaw), o resto aplica.
  class LLMConfigurator
    def initialize(provider_store:, configure: nil)
      @provider_store = provider_store
      @configure = configure # ->(&blk){ blk.call(config_target) }; default = RubyLLM
    end

    # Reconfigura o RubyLLM com `providers` (records raw, com api_key real) ou,
    # se nil, com TODOS do store. -> { applied: [api], skipped: [{api:, reason:}] }.
    def apply(providers = nil)
      records = providers || @provider_store.all_raw
      applied = []
      skipped = []

      with_config do |config|
        records.each do |rec|
          api = fetch(rec, :api)
          key = fetch(rec, :api_key)
          if key.nil? || key.to_s.empty?
            skipped << { api: api, reason: "sem api_key" }
            next
          end

          if set_accessor(config, "#{api}_api_key", key)
            base = fetch(rec, :base_url)
            set_accessor(config, "#{api}_api_base", base) if base && !base.to_s.empty?
            applied << api
          else
            skipped << { api: api, reason: "provider '#{api}' não reconhecido pelo RubyLLM" }
          end
        end
      end

      { applied: applied, skipped: skipped }
    end

    private

    def with_config(&blk)
      if @configure
        @configure.call(&blk)
      else
        require "ruby_llm"
        RubyLLM.configure(&blk)
      end
    end

    def set_accessor(config, name, value)
      setter = "#{name}="
      return false unless config.respond_to?(setter)

      config.public_send(setter, value)
      true
    end

    def fetch(rec, key) = rec[key.to_s] || rec[key.to_sym]
  end
end
