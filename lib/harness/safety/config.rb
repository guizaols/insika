# frozen_string_literal: true

module Harness
  module Safety
    # Per-agent guardrail configuration (RFC-0009 §3.3 / D6), read from
    # `profile.guardrails`. OPT-IN like `capabilities`: an agent that says nothing
    # gets the CONSERVATIVE default — deterministic detectors ON, LLM moderator OFF.
    #
    # Tolerant of the JSON round-trip (string OR symbol keys / values), same
    # discipline as ModelPolicy — the StoredProfileSource persists this as a plain
    # Hash and it comes back stringified.
    #
    #   guardrails: {
    #     input:      true|false,        # run the input guardrail middleware (default true)
    #     output:     true|false,        # run the output filter + validator (default true)
    #     moderator:  "provider/model"|nil,  # LLM moderator model; nil = deterministic only
    #     strictness: "low"|"medium"|"high", # which input categories fire (default medium)
    #     responses:  { <category> => "<safe reply>", ... }  # per-agent override, see below
    #   }
    #
    # `responses` is the CONFIGURATION-OVER-CONVENTION knob (RFC-0009 §7). The engine
    # ships neutral built-in refusals (Safety::SafeResponses::DEFAULTS), but this is
    # OSS across arbitrary businesses/languages, so we never hard-bake tone: an agent
    # overrides the safe reply per category (`injection`/`sexual`/`abuse`/`escalate`/
    # …) or sets a single catch-all `default`. Resolution order (SafeResponses.for):
    # agent[category] → agent["default"] → built-in[category] → built-in[:default].
    class Config
      # strictness -> input categories that the deterministic scan runs.
      #   low    = only injection (+ output redaction) — highest confidence, fewest FPs
      #   medium = injection + sexual + abuse (the default)
      #   high   = same families, reserved for future broader lists
      STRICTNESS_CATEGORIES = {
        low: %i[injection],
        medium: %i[injection sexual abuse],
        high: %i[injection sexual abuse]
      }.freeze

      DEFAULT_STRICTNESS = :medium

      attr_reader :input, :output, :moderator, :strictness, :responses

      def initialize(input:, output:, moderator:, strictness:, responses: {})
        @input = input
        @output = output
        @moderator = moderator
        @strictness = strictness
        @responses = responses # { "category" => "safe reply" }, agent override map
      end

      # Builds a Config from a profile. A nil/empty `guardrails` -> the
      # conservative default (see from_hash).
      def self.from_profile(profile) = from_hash(profile.guardrails)

      def self.from_hash(raw)
        h = symbolize(raw)
        new(
          input: bool(h.fetch(:input, true)),
          output: bool(h.fetch(:output, true)),
          moderator: presence(h[:moderator]),
          strictness: normalize_strictness(h[:strictness]),
          responses: normalize_responses(h[:responses])
        )
      end

      # Input categories the deterministic scan should run, per strictness.
      def input_categories = STRICTNESS_CATEGORIES.fetch(@strictness, STRICTNESS_CATEGORIES[DEFAULT_STRICTNESS])

      # A guardrail is fully off only when BOTH sides are disabled — cheap early-out.
      def enabled? = @input || @output

      def moderator? = !@moderator.nil?

      def self.symbolize(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
      end

      def self.bool(v)
        return v if v == true || v == false
        return false if v.nil?

        s = v.to_s.strip.downcase
        !s.empty? && !%w[false 0 off no].include?(s)
      end

      def self.presence(v) = Harness::Coercion.presence(v)

      def self.normalize_strictness(v)
        sym = v.to_s.strip.downcase.to_sym
        STRICTNESS_CATEGORIES.key?(sym) ? sym : DEFAULT_STRICTNESS
      end

      # Per-agent safe-reply overrides -> { "category" => "text" } with STRING keys
      # (SafeResponses looks up by string), blanks dropped. Tolerant of the JSON
      # round-trip and of a non-Hash (ignored -> {}).
      def self.normalize_responses(v)
        return {} unless v.is_a?(Hash)

        v.each_with_object({}) do |(k, val), acc|
          text = val.to_s.strip
          acc[k.to_s] = text unless text.empty?
        end
      end

      private_class_method :symbolize, :bool, :presence, :normalize_strictness, :normalize_responses
    end
  end
end
