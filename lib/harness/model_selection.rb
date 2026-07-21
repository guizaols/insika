# frozen_string_literal: true

module Harness
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
  #                mid-turn ROTATION across this chain is a follow-up; today the
  #                chain is resolved + surfaced (source/pinned) for telemetry.
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
      apply_thinking(chat, p[:thinking]) if present?(p[:thinking])
      chat
    end

    private

    def apply(chat, method, value)
      chat.public_send(method, value) if chat.respond_to?(method)
    end

    def apply_thinking(chat, effort)
      chat.with_thinking(effort: effort.to_sym) if chat.respond_to?(:with_thinking)
    end

    def numeric?(v) = v.is_a?(Numeric)
    def present?(v) = Harness::Coercion.present?(v)
  end
end
