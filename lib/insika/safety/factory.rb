# frozen_string_literal: true

require_relative "config"
require_relative "detectors"
require_relative "moderator"
require_relative "output_filter"
require_relative "input_guardrail"
require_relative "output_validator"

module Insika
  module Safety
    # Composition helper for the guardrail subsystem (RFC-0009). Keeps the wiring
    # (config.ru / deployment.rb) a one-liner and the Executor decoupled from Safety:
    # the Executor only ever sees a duck-typed `content_filter_factory` callable and
    # reads plain Hash fields (`guardrail_block`/`guardrail_flags`) off the state.
    #
    # The LLM tiers (moderator + validator) resolve their model from the per-agent
    # `guardrails.moderator` ref, falling back to the platform `utility_model`
    # (SettingsStore, #18). RubyLLM is required LAZILY (only when an ask is actually
    # built), mirroring the Executor's create_chat — the core loads without the gem.
    class Factory
      # `settings_store` (optional): source of the platform `utility_model` fallback.
      # nil = no fallback (moderator only when the agent pins its own model ref).
      def initialize(settings_store: nil)
        @settings_store = settings_store
      end

      # The single input-side Middleware for the global MiddlewareStack.
      def input_guardrail
        InputGuardrail.new(moderator_factory: ->(config) { moderator_for(config) })
      end

      # The after_task hook (register with hooks.register(:task, after: ...)).
      def output_validator
        OutputValidator.new(ask_factory: ->(config) { ask_for(config) })
      end

      # Injected into the Executor. ->(state) { OutputFilter | nil }: a fresh stateful
      # filter per turn when the agent has output guardrails on; nil = off (parity).
      def content_filter_factory
        lambda do |state|
          Config.from_profile(state.profile).output ? OutputFilter.new : nil
        end
      end

      private

      def moderator_for(config)
        ask = ask_for(config)
        ask && Moderator.new(ask: ask)
      end

      # Builds the raw ask ->(prompt){text} on the resolved moderator model, or nil
      # when no model is configured / the gem is unavailable.
      def ask_for(config)
        model = resolve_model(config)
        return nil if model.nil?

        provider, name = split_ref(model)
        build_ask(name, provider)
      rescue LoadError, StandardError
        nil # unavailable moderator degrades to deterministic-only (fail-open)
      end

      # Per-agent ref wins; a bare `true`/`on` opts in to the platform utility_model.
      def resolve_model(config)
        ref = config.moderator
        return utility_model if ref.nil? || %w[true on 1 yes].include?(ref.to_s.downcase)

        ref
      end

      def utility_model
        return nil unless @settings_store

        v = @settings_store.get["utility_model"]
        s = v.to_s.strip
        s.empty? ? nil : s
      end

      # "provider/model" -> [provider, model]; "model" -> [nil, model].
      def split_ref(ref)
        prov, name = ref.to_s.split("/", 2)
        name ? [prov, name] : [nil, prov]
      end

      def build_ask(model, provider)
        require "ruby_llm"
        lambda do |prompt|
          RubyLLM.chat(model: model, provider: provider, assume_model_exists: true)
                 .with_temperature(0).ask(prompt).content
        end
      end
    end
  end
end
