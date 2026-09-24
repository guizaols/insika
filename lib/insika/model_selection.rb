# frozen_string_literal: true

module Insika
  # The RESOLVED model decision for a turn (ModelResolver output). Immutable
  # snapshot carried on the TurnState, applied to the RubyLLM chat at stage 5 and
  # surfaced in the turn's usage for telemetry/billing.
  #
  # Fields:
  #   model     -> the resolved model id (String) | nil (RubyLLM's own default)
  #   provider  -> Symbol | nil (nil => RubyLLM infers from the model registry)
  #   source    -> :chat | :agent | :platform_default (WHERE the model came from)
  #   pinned    -> true when the model is a USER pin (per-chat override). A pin
  #                "fails HIGH": no silent fallback (OpenClaw semantics). An agent
  #                model / platform default is NOT pinned -> fallbacks apply.
  #   params    -> generation params (Hash of symbols: temperature/max_tokens/thinking)
  #   fallbacks -> ordered [{ model:, provider: }] to try when NOT pinned. The
  #                mid-turn ROTATION across this chain (plus the profile's own
  #                reliability["fallback"] refs) is WS3's Reliability coordinator;
  #                here the chain is resolved + surfaced (source/pinned) for it.
  ModelSelection = Data.define(:model, :provider, :source, :pinned, :params, :fallbacks) do
    def initialize(model:, provider: nil, source: :platform_default, pinned: false,
                   params: {}, fallbacks: [])
      super
    end

    def pinned? = pinned

    # provider present => tell RubyLLM to trust the id (skip the registry lookup),
    # matching the pre-v2 create_chat behavior.
    def assume_model_exists? = !provider.nil?

    # Applies the generation params to a RubyLLM chat (or any object exposing the
    # same `with_*` fluent API). Pure and duck-typed: a `with_*` the target does
    # not expose is skipped (a fake chat in specs need only implement the ones it
    # asserts). RubyLLM raises on a nil arg, so only PRESENT params are applied.
    # Returns the chat (the `with_*` calls mutate and return self).
    def apply_params(chat)
      p = params || {}
      apply(chat, :with_temperature, p[:temperature]) if numeric?(p[:temperature])
      apply(chat, :with_max_output_tokens, p[:max_tokens]) if numeric?(p[:max_tokens])
      apply_payload_params(chat, p)
      apply_effort(chat, p[:thinking]) if present?(p[:thinking])
      chat
    end

    private

    def apply(chat, method, value)
      chat.public_send(method, value) if chat.respond_to?(method)
    end

    # Provider-specific controls retain their existing wire shape. Token limits
    # use RubyLLM's native setter so each protocol chooses its own wire key.
    def apply_payload_params(chat, p)
      return unless chat.respond_to?(:with_provider_options)

      payload = {}
      toggle = thinking_toggle(p[:thinking])
      payload[:thinking] = { type: toggle } if toggle
      # WHICH upstream serves the model, for a gateway that has several. Authored
      # as `provider_routing` and emitted under the wire key `provider` —
      # OpenRouter's, the only shape that exists for this today; a provider
      # without the field ignores an unknown body key. A raw provider key is
      # not authorable, so the one
      # capability gets a name of its own.
      payload[:provider] = p[:provider_routing] if p[:provider_routing].is_a?(Hash)
      chat.with_provider_options(payload) unless payload.empty?
    end

    # The resolved reasoning control (4-layer). Two axes folded into one field:
    #   off              -> reasoning DISABLED (thinking:{type:disabled})
    #   on               -> reasoning ENABLED, provider-default effort
    #   low|medium|high  -> reasoning enabled at that effort (reasoning_effort)
    # Blank/nil never reaches here (apply_params guards on present?), so no config
    # anywhere = the provider's own default.
    #
    # Native on/off requires model-registry controls, which custom DeepSeek ids
    # may not have. Keep the explicit DeepSeek toggle valid for those models.
    def thinking_toggle(value)
      return nil unless present?(value) && reasoning_toggle_supported?

      case value.to_s
      when "off" then "disabled"
      when "on" then "enabled"
      end
    end

    def apply_effort(chat, value)
      return unless %w[low medium high].include?(value.to_s)

      chat.with_thinking(effort: value.to_sym) if chat.respond_to?(:with_thinking)
    end

    def reasoning_toggle_supported?
      provider.nil? || provider.to_sym == :deepseek
    end

    def numeric?(v) = v.is_a?(Numeric)
    def present?(v) = Insika::Coercion.present?(v)
  end

  # The selectable reasoning values (4-layer). Blank/absent = inherit the
  # broader layer; these are the explicit choices. Shared with the Studio forms.
  # Defined on the class OUTSIDE the Data.define block on purpose: a constant
  # assigned inside the block would land in the enclosing lexical scope (Insika),
  # not on ModelSelection.
  ModelSelection::THINKING_LEVELS = %w[off on low medium high].freeze
end
