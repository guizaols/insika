# frozen_string_literal: true

require_relative "config"
require_relative "detectors"
require_relative "moderator"
require_relative "judge_moderator"
require_relative "output_filter"
require_relative "input_guardrail"
require_relative "output_validator"
# the grounding validator (flagged as the OutputValidator's first
# step) and the enforcer (the executor's stage-8 boundary call). Pure Ruby.
require_relative "grounding_validator"
require_relative "grounding_enforcer"

module Insika
  module Safety
    # Composition helper for the guardrail subsystem. Keeps the wiring
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
      # `llm` (optional): the graph's own RubyLLM context. nil = the
      # process-wide RubyLLM constant. A guardrail asking on the global while the
      # turn asks on the graph's key is a leak with a false sense of isolation, so
      # this seam is part of and not a follow-up.
      def initialize(settings_store: nil, llm: nil)
        @settings_store = settings_store
        @llm = llm
      end

      # The single input-side Middleware for the global MiddlewareStack.
      def input_guardrail
        InputGuardrail.new(moderator_factory: ->(config) { moderator_for(config) })
      end

      # The after_task hook (register with hooks.register(:task, after: ...)).
      # the grounding validator is the OutputValidator's FIRST step —
      # it runs before the output gate (D9), so grounding is independent of the
      # guardrails opt-in.
      def output_validator
        OutputValidator.new(ask_factory: ->(config) { ask_for(config) },
                            grounding: GroundingValidator.new)
      end

      # the `:enforce` boundary step the Executor calls between
      # stages 6 and 8. Inert unless the profile's grounding.mode is :enforce.
      def grounding_enforcer = GroundingEnforcer.new

      # Injected into the Executor. ->(state) { OutputFilter | nil }: a fresh stateful
      # filter per turn when the agent has output guardrails on; nil = off (parity).
      def content_filter_factory
        lambda do |state|
          config = Config.from_profile(state.profile)
          config.output ? OutputFilter.new(corpus: config.corpus) : nil
        end
      end

      private

      # A `typesafe/<model>` ref is a judgment model: it answers the category as a
      # typed choice and hands unsure cases to the chat moderator on the platform
      # utility_model. Any other ref is the chat moderator itself.
      # ponytail: provider check is "typesafe" only; widen when another judgment
      # provider (openai gpt-6-luna, ollama clef) is actually used.
      def moderator_for(config)
        provider, name = split_ref(resolve_model(config))
        return chat_moderator(config) unless provider == "typesafe"

        JudgeModerator.new(judge: build_judge(name, provider), fallback: utility_moderator)
      rescue LoadError, StandardError
        nil
      end

      def chat_moderator(config)
        ask = ask_for(config)
        ask && Moderator.new(ask: ask)
      end

      def utility_moderator
        ref = utility_model
        return nil unless ref

        provider, name = split_ref(ref)
        Moderator.new(ask: build_ask(name, provider))
      end

      def build_judge(model, provider)
        require "ruby_llm"
        llm = @llm || RubyLLM
        lambda do |message|
          answer = llm.judge(message, model: model, provider: provider, assume_model_exists: true,
                                      questions: JudgeModerator::QUESTION)["category"]
          { "category" => answer.choice.to_s, "confidence" => answer.confidence.to_f }
        end
      end

      # Builds the raw ask ->(prompt){text} on the resolved moderator model, or nil
      # when no model is configured / the gem is unavailable.
      def ask_for(config)
        model = resolve_model(config)
        # A judgment model cannot write the text this ask expects; the output
        # validator uses the utility_model instead (same as the judge's fallback).
        model = utility_model if split_ref(model).first == "typesafe"
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
        llm = @llm || RubyLLM
        # A bare ref ("deepseek-flash") resolves through the registry, like the
        # Executor's build_chat; assume_model_exists without a provider raises.
        lambda do |prompt|
          llm.chat(model: model, provider: provider, assume_model_exists: !provider.nil?)
             .with_temperature(0).ask(prompt).content
        end
      end
    end
  end
end
