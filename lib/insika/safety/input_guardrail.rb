# frozen_string_literal: true

require_relative "../middleware"
require_relative "detectors"
require_relative "safe_responses"
require_relative "config"

module Insika
  module Safety
    # Input guardrail as a Middleware (RFC-0009 §3.1). It sits on the ONE seam that
    # already short-circuits structurally (stage 4: a link that does not call `nxt`),
    # and uses the NEW graceful-halt contract: instead of `halt_reason` (which the
    # Executor maps to a turn FAILURE), it sets `halt_response` (a safe reply) +
    # `guardrail_block` (audit metadata) and returns without calling `nxt`. The
    # Executor completes the turn with that safe reply, never touching the LLM.
    #
    # Two tiers (D2):
    #   1. deterministic scan (always, cheap, zero-token) — Detectors#scan_input;
    #   2. LLM moderator (opt-in per agent) — only when the deterministic tier let
    #      the message through, so the cheap layer short-circuits the expensive one.
    #
    # Auto-disables per turn by reading `guardrails:` off the profile (Config): the
    # link lives ONCE in the global MiddlewareStack — there is no per-agent stack.
    #
    # `moderator_factory` (optional): ->(config) { Moderator | nil }, built by the
    # Safety::Factory. nil = deterministic only (Fase A/B parity).
    class InputGuardrail < Insika::Middleware
      def initialize(moderator_factory: nil)
        @moderator_factory = moderator_factory
      end

      def call(state, &nxt)
        config = Config.from_profile(state.profile)
        return nxt.call(state) unless config.input

        hit = Detectors.scan_input(state.message.to_s, categories: config.input_categories)
        return block(state, config, category: hit[:category], source: :deterministic, detail: hit[:matched]) if hit

        if config.moderator? && (mod = build_moderator(config))
          verdict = mod.classify(state.message.to_s)
          if verdict.block?
            category = moderator_category(verdict)
            return block(state, config, category: category, source: :moderator,
                                        detail: verdict.reason, action: verdict.action)
          end
        end

        nxt.call(state)
      end

      private

      def build_moderator(config)
        @moderator_factory&.call(config)
      end

      # The block category. `escalate` (an ACTION) becomes the `escalate` category so
      # the agent can address it; otherwise the moderator's own category flows
      # through UNCOLLAPSED — the safe-reply lookup (SafeResponses.for) resolves an
      # unknown one to the agent's `default` / the neutral built-in, so we don't need
      # to force it into a fixed bucket here (configuration over convention, §7).
      def moderator_category(verdict)
        return :escalate if verdict.action.to_s == "escalate"

        cat = verdict.category.to_s
        cat.empty? ? :default : cat.to_sym
      end

      # Sets the graceful-halt fields and short-circuits (does NOT call nxt). The
      # Executor reads `guardrail_block` to emit `:guardrail_blocked` (single-emitter
      # discipline) and `halt_response` to complete the turn. The safe reply honors
      # the agent's per-category / catch-all overrides (config.responses) before any
      # built-in default. `detail`/matched value is NOT a raw secret — it is an
      # injection/abuse phrase, safe to log; the Executor routes it through audit.
      def block(state, config, category:, source:, detail: nil, action: "refuse")
        state.halt_response = SafeResponses.for(category, overrides: config.responses)
        state.guardrail_block = {
          category: category.to_s,
          source: source.to_s,
          action: action.to_s,
          detail: detail.to_s[0, 200]
        }
        nil
      end
    end
  end
end
