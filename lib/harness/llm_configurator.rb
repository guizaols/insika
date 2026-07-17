# frozen_string_literal: true

module Harness
  # Applies the authored LLM providers (LLMProviderStore) to RubyLLM at RUNTIME.
  # Goal: swap a provider's key/base WITHOUT a restart —
  # RubyLLM exposes `config.<api>_api_key=` / `config.<api>_api_base=`, so
  # reconfiguring is a matter of setting those accessors per provider.
  #
  # Core constraint: this file does NOT require ruby_llm at load-time — the
  # `require` is lazy, inside `apply` (and injectable via `configure:` for tests,
  # which run without the gem/key). A provider that RubyLLM doesn't recognize (no
  # matching accessor) does NOT blow up: it goes into `skipped` (degrades to "restart
  # recommended", like OpenClaw), the rest applies.
  class LLMConfigurator
    def initialize(provider_store:, configure: nil)
      @provider_store = provider_store
      @configure = configure # ->(&blk){ blk.call(config_target) }; default = RubyLLM
    end

    # Reconfigures RubyLLM with `providers` (raw records, with the real api_key) or,
    # if nil, with ALL from the store. -> { applied: [api], skipped: [{api:, reason:}] }.
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
            skipped << { api: api, reason: "provider '#{api}' not recognized by RubyLLM" }
          end
        end
      end

      { applied: applied, skipped: skipped }
    end

    # UNDOES a provider's config in RubyLLM at runtime (delete without a restart,
    # §9.5): clears `<api>_api_key`/`<api>_api_base`. A provider that RubyLLM
    # doesn't recognize (no accessor) -> unapplied: false (nothing applied, nothing to undo).
    # -> { unapplied: bool }.
    def unapply(api)
      api = api.to_s
      unapplied = false
      with_config do |config|
        unapplied = set_accessor(config, "#{api}_api_key", nil)
        set_accessor(config, "#{api}_api_base", nil)
      end
      { unapplied: unapplied }
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
