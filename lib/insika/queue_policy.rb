# frozen_string_literal: true

require_relative "coercion"

module Insika
  # RFC-0015 §4 — what happens to an inbound message for a session that is ALREADY
  # busy. Today the engine has exactly one answer, "it waits in line"; this names
  # that answer `followup` and adds `collect`, which merges fragments that arrive
  # BEFORE the turn starts into a single turn.
  #
  # Resolution per message, the order EdgeLimiter already documents
  # (`edge_limiter.rb:17`) — configuration over convention:
  #
  #   session vars["queue_mode"]   — one conversation pinned by an operator
  #   profile.limits[:<key>]       — per-agent (a PRESENT key wins, incl. nil/0 = off)
  #   settings["queue"][<key>]     — platform default, editable in the Studio
  #   DEFAULTS[<key>]              — = today's behavior
  #
  # Every default is off: a bare wiring behaves exactly as it did before this
  # existed. The knobs live in `profile.limits` next to `tool_concurrency` and
  # `turn_timeout` because they are bounds on the same thing — how much work one
  # turn is allowed to absorb.
  class QueuePolicy
    # Delivered. A mode outside this set is refused rather than approximated.
    IMPLEMENTED_MODES = %i[followup collect].freeze
    # Specified by RFC-0015 but delivered in later PRs. Named so a typo and a
    # not-yet-shipped mode are DIFFERENT errors: silently treating `steer` as
    # `followup` would look exactly like steering that never fires.
    PLANNED_MODES = %i[steer interrupt].freeze

    DEFAULTS = {
      queue_mode: :followup,
      debounce_ms: 0,       # 0 = no window: dequeue immediately, today's path
      debounce_max_ms: 10_000 # ceiling on the TOTAL deferral (see #debounce_deadline_ms)
    }.freeze

    attr_reader :mode, :debounce_ms, :debounce_max_ms

    # profile: an AgentProfile (or nil); settings_store: nil = no platform layer;
    # vars: the session's vars Hash (string keys, as the SessionStore returns).
    def self.resolve(profile, settings_store: nil, vars: nil)
      platform = ((settings_store&.get || {})["queue"] || {})
      limits = profile.respond_to?(:limits) ? (profile.limits || {}) : {}

      new(
        mode: mode!(pick_mode(vars, limits, platform)),
        debounce_ms: pick(:debounce_ms, limits, platform),
        debounce_max_ms: pick(:debounce_max_ms, limits, platform)
      )
    end

    def initialize(mode:, debounce_ms:, debounce_max_ms:)
      @mode = mode
      @debounce_ms = [debounce_ms.to_i, 0].max
      # A non-positive ceiling would mean "defer forever", which nobody wants and
      # which a stray 0 in a config would silently buy. Fall back to the default.
      max = debounce_max_ms.to_i
      @debounce_max_ms = max.positive? ? max : DEFAULTS[:debounce_max_ms]
    end

    # Does this policy want messages held at the door at all?
    def debounce? = @debounce_ms.positive?

    # Does this policy merge into a turn that has not started yet?
    def collect? = @mode == :collect

    # A mode name -> Symbol, or raise. Blank = the default (an absent key is not
    # an error; a WRONG key is).
    def self.mode!(value)
      return DEFAULTS[:queue_mode] if Coercion.blank?(value)

      name = value.to_s.strip.downcase.to_sym
      return name if IMPLEMENTED_MODES.include?(name)

      if PLANNED_MODES.include?(name)
        raise Insika::ValidationError,
              "queue_mode '#{name}' is specified by RFC-0015 but not implemented yet " \
              "(available: #{IMPLEMENTED_MODES.join(', ')})"
      end

      raise Insika::ValidationError,
            "unknown queue_mode: #{value.inspect} " \
            "(expected #{(IMPLEMENTED_MODES + PLANNED_MODES).join(', ')})"
    end

    # A present key WINS even carrying nil/0 — "off for this agent", never
    # "inherit the platform default". Same semantics EdgeLimiter documents at
    # `edge_limiter.rb:57`, and for the same reason: an imported pack carrying an
    # explicit null must not silently re-enable a platform behavior.
    def self.pick(key, limits, platform)
      return limits[key].to_i if limits.key?(key)
      return platform[key.to_s].to_i if platform.key?(key.to_s)

      DEFAULTS[key]
    end

    def self.pick_mode(vars, limits, platform)
      from_vars = (vars || {})["queue_mode"] || (vars || {})[:queue_mode]
      return from_vars if Coercion.present?(from_vars)
      return limits[:queue_mode] if limits.key?(:queue_mode)

      platform["queue_mode"]
    end

    private_class_method :pick, :pick_mode
  end
end
