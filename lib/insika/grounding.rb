# frozen_string_literal: true

require_relative "coercion"
require_relative "grounding/matcher"

module Insika
  #   — the profile-facing half of grounding: parse the pack's
  # `grounding` data into the per-turn Grounding object (mode + matcher).
  #
  # Data (on the AgentProfile):
  #
  #   { "mode" => "flag"|"enforce"|"off",
  #     "matcher" => { "sku" => "\b[A-Z]{2,4}\d{4,8}\b" } }
  #
  # Absent = the whole feature is OFF (parity). The matcher is built ONCE per
  # turn (profile parse) and cached on the Grounding object. A `sku` that does
  # not compile, or exceeds 256 chars, is a ValidationError at build — the
  # engine refuses only uncompileable data; a matcher with no sku matches
  # nothing (grounding on is harmless but useless; doctor warns).
  class Grounding
    MODES = %w[flag enforce off].freeze
    SKU_MAX = 256

    attr_reader :mode, :matcher

    # raw: the profile's `grounding` Hash | nil | false -> Grounding | nil.
    # nil/false = off. A non-Hash (e.g. true) reads as an empty config.
    def self.parse(raw)
      return nil if raw.nil? || raw == false

      h = Coercion.deep_stringify(raw.is_a?(Hash) ? raw : {})
      mode = MODES.include?(h["mode"].to_s) ? h["mode"].to_s : "flag" # default :flag
      new(mode: mode, matcher: GroundingMatcher.build(h["matcher"]))
    end

    def initialize(mode:, matcher:)
      @mode = mode
      @matcher = matcher
    end

    def enforce? = mode == "enforce"
    def off? = mode == "off"
  end
end
