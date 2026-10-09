# frozen_string_literal: true

require "json"
require "time"

module Insika
  # RubyLLM's model catalog (ids, context windows, prices) kept in the shared
  # store instead of the gem's bundled file, which ages with every deploy.
  #
  # Two roles:
  #   - RubyLLM's `model_registry_store` (#read / #write): the catalog lives in
  #     one place for every worker and survives restarts.
  #   - a Tick duty (#run): one worker per interval refreshes from the published
  #     catalog and the configured providers; every other worker reloads the
  #     stored catalog when it changes. A failed refresh keeps the catalog it had
  #     and is retried after RETRY_AFTER, never on every tick.
  class ModelRegistry
    SCOPE = "model_registry"
    INTERVAL = 86_400
    RETRY_AFTER = 3600

    def initialize(store:, interval: INTERVAL, logger: nil,
                   refresher: -> { RubyLLM::Models.refresh(remote_only: true) })
      @store = store
      @interval = interval.to_i
      @logger = logger
      @refresher = refresher
      @loaded = nil
    end

    # --- RubyLLM model_registry_store -------------------------------------

    def read
      raw = @store.get(SCOPE, "catalog") or return []
      RubyLLM::Models::Registry.models_from_data(JSON.parse(raw, symbolize_names: true))
    end

    # RubyLLM hands a Models registry; stored as JSON so RubyLLM's own reader parses it back.
    def write(registry)
      models = registry.respond_to?(:all) ? registry.all : Array(registry)
      @store.transaction do
        @store.set(SCOPE, "catalog", JSON.generate(models.map(&:to_h)))
        @store.set(SCOPE, "meta", { "refreshed_at" => Time.now.utc.iso8601(6), "models" => models.size })
      end
    end

    def description = "Insika store (#{SCOPE})"

    # --- Tick duty ---------------------------------------------------------

    # -> { refreshed: true, models: n } | { reloaded: true } | nil (nothing to do)
    def run(now: Time.now.utc)
      return nil unless @interval.positive?

      install
      return refresh if claim(now)

      reload
    end

    def refreshed_at = @store.get(SCOPE, "meta")&.fetch("refreshed_at", nil)

    private

    # RubyLLM reads and refreshes through the store from here on; a worker that
    # already loaded the bundled catalog switches on its next #reload.
    def install
      require "ruby_llm"
      RubyLLM.config.model_registry_store = self unless RubyLLM.config.model_registry_store.equal?(self)
    end

    def refresh
      @refresher.call
      @loaded = refreshed_at
      { refreshed: true, models: RubyLLM.models.all.size }
    rescue StandardError => e
      @logger&.warn("model registry refresh failed: #{e.class}: #{e.message}")
      { refreshed: false, error: e.class.name }
    end

    def reload
      stamp = refreshed_at
      return nil if stamp.nil? || stamp == @loaded

      RubyLLM.models.load_from_store
      @loaded = stamp
      { reloaded: true }
    end

    # One refresher per window across workers (Tick's claim discipline): due once
    # `refreshed_at` is an interval old, and a failed attempt waits RETRY_AFTER.
    def claim(now)
      @store.transaction do
        attempted = time(@store.get(SCOPE, "claim")&.fetch("attempted_at", nil))
        refreshed = time(refreshed_at)
        due = refreshed.nil? || now - refreshed >= @interval
        next false unless due && (attempted.nil? || now - attempted >= RETRY_AFTER)

        @store.set(SCOPE, "claim", { "attempted_at" => now.iso8601 })
        true
      end
    end

    def time(value)
      value && Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
