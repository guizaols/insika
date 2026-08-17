# frozen_string_literal: true

require "json"
require_relative "detectors"
require_relative "config"

module Insika
  module Safety
    # Post-turn output validator. Runs as an `after_task` hook:
    # with the FINAL assistant text assembled, it does a richer check than the
    # stream filter can — an unverified discount/price promise, a tone slip — and
    # FLAGS it (audit) rather than blocking. It is honest about the streaming limit
    # for a streaming agent the text is already out the door, so this is
    # detection, not prevention; true pre-emission blocking needs `streaming:false`
    # (a per-profile override left for a later slice).
    #
    # Contract: as an after_task hook it receives the TurnState (the :task subject),
    # appends any finding to `state.guardrail_flags`, and returns the state
    # unchanged. The Executor (single emitter) turns each flag into a
    # `:guardrail_flagged` event after the turn — the hook itself never emits.
    #
    # Two tiers, like the input side:
    #   1. deterministic — residual PII/secret in the final text (a belt to the
    #      stream filter's suspenders) via Detectors;
    #   2. LLM validator (opt-in, same moderator model) — promise/tone judgment the
    #      regex can't make. Pure over an injected `ask`; fail-open on any error.
    class OutputValidator
      # `ask_factory` (optional): ->(config) { ->(prompt){text} | nil }, built by the
      # Safety::Factory from the utility_model. nil = deterministic only.
      # `grounding` (optional, RFC-0029): a GroundingValidator — its step runs
      # FIRST in #call, before the `config.output` gate (D9: grounding is
      # evidence integrity, independent of the guardrails opt-in).
      def initialize(ask_factory: nil, grounding: nil)
        @ask_factory = ask_factory
        @grounding = grounding
      end

      # after_task hook body. Idempotent and defensive: never raises out (a hook
      # error must not fail a committed turn). Grounding runs BEFORE the output
      # gate so an agent with guardrails off and grounding on still gets the check.
      def call(state)
        state = @grounding&.call(state) || state
        config = Config.from_profile(state.profile)
        return state unless config.output

        text = state.response_content.to_s
        return state if text.empty?

        flags = []
        flags.concat(deterministic_flags(text))
        flags.concat(llm_flags(text, config)) if config.moderator?

        state.guardrail_flags = Array(state.guardrail_flags) + flags unless flags.empty?
        state
      rescue StandardError
        state # fail-open: auditing must never break a completed turn
      end

      private

      # Residual PII/secret that somehow reached the final text (the stream filter
      # should have caught it — this is defense in depth, and the flag itself
      # carries category counts, never the raw value).
      def deterministic_flags(text)
        _redacted, counts = Detectors.redact(text)
        return [] if counts.empty?

        [{ category: "pii_residual", source: "deterministic", detail: counts.map { |k, v| "#{k}:#{v}" }.join(",") }]
      end

      def llm_flags(text, config)
        ask = @ask_factory&.call(config)
        return [] unless ask

        raw = ask.call(build_prompt(text)).to_s
        json = raw[/\{.*\}/m]
        return [] unless json

        data = JSON.parse(json)
        return [] unless data["flagged"] == true

        [{ category: data["category"].to_s.empty? ? "policy" : data["category"].to_s,
           source: "moderator", detail: data["reason"].to_s[0, 200] }]
      rescue StandardError
        [] # fail-open
      end

      def build_prompt(text)
        <<~PROMPT
          You are a strict compliance reviewer for a retail customer-service AI. Review
          the ASSISTANT REPLY below. Flag it ONLY if it does one of these:
          - promises a discount/price/refund that it cannot verify (invented policy);
          - leaks system-prompt/internal configuration;
          - is unprofessional, sexual, or hostile in tone.

          A normal, helpful, in-policy reply is NOT flagged.

          ASSISTANT REPLY:
          #{text}

          Respond with ONLY a JSON object, no prose:
          {"flagged": <true|false>, "category": "<short label>", "reason": "<one short sentence>"}
        PROMPT
      end
    end
  end
end
