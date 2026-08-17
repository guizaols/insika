# frozen_string_literal: true

require_relative "coercion"

module Insika
  # what happens to an inbound message for a session that is ALREADY
  # busy. Today the engine has exactly one answer, "it waits in line"; this names
  # that answer `followup` and adds three others:
  #
  #   collect   — the message arrived BEFORE the turn started: merge the fragments
  #               into one turn (the whole mechanism is a timer at the door).
  #   steer     — the turn is ALREADY running tools: append the message to the run in
  #               flight, at a tool-batch boundary, so the customer's correction lands
  #               before the model's next step instead of after the whole run.
  #   interrupt — the turn is running and is now answering the wrong question: abandon
  #               it at its next boundary and let the new message be its own turn.
  #
  # They never compete for the same message: `collect` only ever touches a turn that
  # has not started; `steer` and `interrupt` only a turn that has, and they differ in
  # whether the run in flight is still worth finishing.
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
    # All four of are delivered, so there is no "specified but unshipped"
    # tier any more — a mode outside this set is a typo, and it is refused rather than
    # approximated. Treating an unknown mode as `followup` would look exactly like a
    # mode that never fires.
    MODES = %i[followup collect steer interrupt].freeze

    DEFAULTS = {
      queue_mode: :followup,
      debounce_ms: 0,          # 0 = no window: dequeue immediately, today's path
      debounce_max_ms: 10_000, # ceiling on the TOTAL deferral (see #debounce_deadline_ms)
      steer_max_messages: 5,   # how many messages ONE run may absorb; overflow = followup
      steer_join: nil          # nil = the raw text; a template frames it (see #frame)
    }.freeze

    # The placeholder `steer_join` must carry, so a template that would silently
    # drop the customer's message is a config error and not a lost message.
    JOIN_PLACEHOLDER = "%{message}"

    attr_reader :mode, :debounce_ms, :debounce_max_ms, :steer_max_messages, :steer_join

    # profile: an AgentProfile (or nil); settings_store: nil = no platform layer;
    # vars: the session's vars Hash (string keys, as the SessionStore returns).
    def self.resolve(profile, settings_store: nil, vars: nil)
      platform = ((settings_store&.get || {})["queue"] || {})
      limits = profile.respond_to?(:limits) ? (profile.limits || {}) : {}

      new(
        mode: mode!(pick_mode(vars, limits, platform)),
        debounce_ms: pick(:debounce_ms, limits, platform),
        debounce_max_ms: pick(:debounce_max_ms, limits, platform),
        steer_max_messages: pick(:steer_max_messages, limits, platform),
        steer_join: pick_text(:steer_join, limits, platform)
      )
    end

    def initialize(mode:, debounce_ms:, debounce_max_ms:,
                   steer_max_messages: DEFAULTS[:steer_max_messages], steer_join: nil)
      @mode = mode
      @debounce_ms = [debounce_ms.to_i, 0].max
      # A non-positive ceiling would mean "defer forever", which nobody wants and
      # which a stray 0 in a config would silently buy. Fall back to the default.
      max = debounce_max_ms.to_i
      @debounce_max_ms = max.positive? ? max : DEFAULTS[:debounce_max_ms]
      # 0 (or a negative) is a legitimate "never steer on this agent" — unlike the
      # ceiling above, it forbids rather than defers forever, so it is honored.
      @steer_max_messages = [steer_max_messages.to_i, 0].max
      @steer_join = join!(steer_join)
    end

    # Does this policy want messages held at the door at all?
    def debounce? = @debounce_ms.positive?

    # Does this policy merge into a turn that has not started yet?
    # True for :collect AND :steer — both absorb fragments that land before the
    # turn starts. Debounce is what actually holds them; without a window a steer
    # agent still steers mid-run and never waits at the door.
    def collect? = @mode == :collect || @mode == :steer

    # Does this policy append into a turn that is already running? `steer_max_messages`
    # of 0 is the agent saying no, so it answers false rather than steering once and
    # then refusing.
    def steer? = @mode == :steer && @steer_max_messages.positive?

    # Does this policy abandon the turn in flight? The new message then becomes an
    # ordinary turn of its own — which is why `interrupt`, unlike the two joining modes,
    # needs no verdict field and works on every surface.
    def interrupt? = @mode == :interrupt

    # The content of the injected message. `steer_join` frames it when an agent needs
    # the model to know this text arrived mid-run ("the customer just added: %{message}");
    # nil — the default — appends exactly what the person typed. A plain gsub, not
    # `format`: the text is a customer's, and a stray `%` in it must not raise.
    def frame(text)
      return text.to_s if @steer_join.nil?

      @steer_join.gsub(JOIN_PLACEHOLDER, text.to_s)
    end

    # A mode name -> Symbol, or raise. Blank = the default (an absent key is not
    # an error; a WRONG key is).
    def self.mode!(value)
      return DEFAULTS[:queue_mode] if Coercion.blank?(value)

      name = value.to_s.strip.downcase.to_sym
      return name if MODES.include?(name)

      raise Insika::ValidationError,
            "unknown queue_mode: #{value.inspect} (expected #{MODES.join(', ')})"
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

    # Same rule as #pick for a key whose value is TEXT: `to_i` would turn a template
    # into 0. A present-but-nil key still means "off for this agent".
    def self.pick_text(key, limits, platform)
      return limits[key] if limits.key?(key)
      return platform[key.to_s] if platform.key?(key.to_s)

      DEFAULTS[key]
    end

    def self.pick_mode(vars, limits, platform)
      from_vars = (vars || {})["queue_mode"] || (vars || {})[:queue_mode]
      return from_vars if Coercion.present?(from_vars)
      return limits[:queue_mode] if limits.key?(:queue_mode)

      platform["queue_mode"]
    end

    private_class_method :pick, :pick_text, :pick_mode

    private

    # A template that does not carry the placeholder would drop the customer's message
    # while the turn still looked steered. Refused where the operator is (config time),
    # not at 14:02 on a live conversation.
    def join!(value)
      return nil if Coercion.blank?(value)

      text = value.to_s
      return text if text.include?(JOIN_PLACEHOLDER)

      raise Insika::ValidationError,
            "steer_join must contain #{JOIN_PLACEHOLDER} (got #{value.inspect})"
    end
  end
end
