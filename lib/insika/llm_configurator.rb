# frozen_string_literal: true

module Insika
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
  #
  # ⚠️ GOTCHA — the DEFAULT target is a global singleton (RubyLLM research).
  # With no `configure:`, `apply`/`unapply` mutate the PROCESS-WIDE config
  # (`RubyLLM.config`). They are therefore admin operations (rare, operator-driven:
  # a provider key/base edit in the Studio), NOT a per-request/per-turn path — a
  # concurrent turn reading the config mid-mutation would observe a torn key/base.
  # This is tolerable ONLY because reconfiguration is infrequent and single-writer
  # (one reactor). Do NOT call this per turn, and do NOT reach for it to vary the
  # MODEL per turn — the model is chosen at chat build time (ModelResolver ->
  # chat(model:)), never by mutating the global.
  #
  # PER-GRAPH credentials are no longer hypothetical: the DSL runtime
  # passes `configure:` targeting its own `RubyLLM.context` — an isolated config dup
  # — so an operator's key edit in an EMBEDDED graph applies to that graph and stops
  # there. See `DSL::Runtime#llm_configure` and docs/EMBEDDING.md.
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

          remember_boot(config, api)
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

    # Re-applies the stored providers when they changed since THIS process last
    # applied them. The Studio's `apply` reaches only the worker that served the
    # edit; every other worker (and every worker after a restart) gets the
    # provider here. Called per chat build, so it mutates the config only when the
    # store changed, which is rare. Inside a turn the read comes from the
    # ConfigStore cache. A provider this method applied and that no longer has a
    # key (deleted, or its key cleared) is unapplied; a key it never applied, such
    # as one from the environment, is never cleared. A store error keeps the
    # current config: the next call retries, and the chat is not failed for it.
    def refresh
      records = @provider_store.all_raw
      digest = records.hash
      return if digest == @refreshed_digest

      applied = apply(records)[:applied].map(&:to_s)
      (Array(@refreshed_apis) - applied).each { |api| unapply(api) }
      @refreshed_apis = applied
      @refreshed_digest = digest
    rescue StandardError => e
      warn "[insika] LLM providers not refreshed, keeping the current ones: #{e.class}: #{e.message}"
    end

    # UNDOES a provider's config in RubyLLM at runtime (delete without a restart):
    # `<api>_api_key`/`<api>_api_base` go back to what they were before this
    # configurator first set them (nil when nothing was). A provider that RubyLLM
    # doesn't recognize (no accessor) -> unapplied: false (nothing applied, nothing to undo).
    # -> { unapplied: bool }.
    def unapply(api)
      api = api.to_s
      # never applied here (another worker served the edit): nothing of ours to undo
      return { unapplied: false } unless boot_values.key?(api)

      unapplied = false
      with_config do |config|
        key, base = boot_values[api]
        unapplied = set_accessor(config, "#{api}_api_key", key)
        set_accessor(config, "#{api}_api_base", base)
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

    # The key/base a provider had before this configurator first overrode it (the
    # environment's, or nil), so removing the authored one puts those back instead
    # of leaving the provider without credentials.
    def remember_boot(config, api)
      return if boot_values.key?(api.to_s)

      boot_values[api.to_s] = %w[key base].map do |part|
        getter = "#{api}_api_#{part}"
        config.public_send(getter) if config.respond_to?(getter)
      end
    end

    def boot_values = (@boot_values ||= {})

    def set_accessor(config, name, value)
      setter = "#{name}="
      return false unless config.respond_to?(setter)

      config.public_send(setter, value)
      true
    end

    def fetch(rec, key) = rec[key.to_s] || rec[key.to_sym]
  end
end
