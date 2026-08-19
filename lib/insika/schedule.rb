# frozen_string_literal: true

module Insika
  # the parsed recurring-schedule declaration of ONE agent —
  # the ONLY shape the engine accepts, shared by the ScheduleEngine, the
  # doctor and the Studio. Pure value object (the followup-policy precedent).
  #
  # One schedule: a name, a trigger (`cron` OR `every`, never both), a
  # timezone for cron materialization, the synthetic inbound message, a
  # session mode (a fresh session per run, or a standing one), per-run
  # overrides (turn_timeout / max_tool_calls / model) and an enabled flag.
  #
  # `parse` returns nil on a malformed hash (the engine SKIPS, the doctor
  # explains, the Studio refuses); `parse!` raises Insika::ValidationError
  # naming the exact defect.
  class Schedule
    SESSION_MODES = %w[new fixed].freeze
    OVERRIDE_KEYS = %w[turn_timeout max_tool_calls model].freeze
    ID_RE = /\A[a-z][a-z0-9_-]*\z/

    attr_reader :id, :every, :cron, :tz, :message, :session_mode, :session_id,
                :overrides, :enabled

    def self.parse(hash)
      new(hash)
    rescue Insika::ValidationError
      nil
    end

    def self.parse!(hash)
      new(hash)
    end

    def initialize(hash)
      raise Insika::ValidationError, "schedule: declaration must be a Hash" unless hash.is_a?(Hash)

      h = hash.transform_keys(&:to_s)
      @id = id_of(h)
      @every = every_of(h)
      @cron = cron_of(h)
      if @cron.nil? && @every.nil?
        raise Insika::ValidationError,
              "schedule '#{@id}': a trigger is required — declare cron or every"
      end
      @tz = tz_of(h)
      @message = message_of(h)
      @session_mode = session_mode_of(h)
      @session_id = session_id_of(h)
      @overrides = overrides_of(h)
      @enabled = h.key?("enabled") ? h["enabled"] == true : true
      freeze
    end

    def cron? = !@cron.nil?
    def every? = !@every.nil?
    def fixed_session? = @session_mode == "fixed"

    def to_h
      { "id" => @id, "cron" => @cron, "every" => @every, "tz" => @tz,
        "message" => @message, "session_mode" => @session_mode,
        "session_id" => @session_id, "overrides" => @overrides,
        "enabled" => @enabled }.compact
    end

    private

    def id_of(h)
      id = h["id"].to_s.strip.downcase
      unless ID_RE.match?(id)
        raise Insika::ValidationError,
              "schedule.id must match #{ID_RE.inspect}, got: #{h['id'].inspect}"
      end

      id
    end

    def every_of(h)
      every = h["every"]
      return nil if every.nil?

      unless every.is_a?(Integer) && every.positive?
        raise Insika::ValidationError,
              "schedule.every must be a positive integer of seconds, got: #{h['every'].inspect}"
      end

      every
    end

    def cron_of(h)
      cron = h["cron"]
      return nil if cron.nil?

      if h.key?("every") && !h["every"].nil?
        raise Insika::ValidationError,
              "schedule '#{@id}': cron and every are mutually exclusive — declare exactly one trigger"
      end

      Insika::Cron.new(cron) # raises ValidationError on a malformed expression
      cron.to_s
    end

    def tz_of(h)
      tz = h["tz"].to_s
      tz = "Etc/UTC" if tz.empty?
      unless Insika::Timezone.known?(tz)
        raise Insika::ValidationError, "schedule '#{@id}'.tz is not a valid IANA timezone: #{tz.inspect}"
      end

      tz
    end

    def message_of(h)
      message = h["message"]
      if Coercion.blank?(message)
        raise Insika::ValidationError,
              "schedule '#{@id}'.message is required — the synthetic inbound that kicks each run"
      end

      message.to_s
    end

    def session_mode_of(h)
      mode = h["session_mode"]
      return "new" if mode.nil?

      mode = mode.to_s
      unless SESSION_MODES.include?(mode)
        raise Insika::ValidationError,
              "schedule '#{@id}'.session_mode must be one of #{SESSION_MODES.inspect}, got: #{h['session_mode'].inspect}"
      end

      mode
    end

    def session_id_of(h)
      session_id = h["session_id"]
      return nil if session_id.nil?

      session_id.to_s
    end

    def overrides_of(h)
      overrides = h["overrides"]
      return nil if overrides.nil?

      raise Insika::ValidationError, "schedule '#{@id}'.overrides must be a Hash" unless overrides.is_a?(Hash)

      overrides = overrides.transform_keys(&:to_s)
      unknown = overrides.keys - OVERRIDE_KEYS
      unless unknown.empty?
        raise Insika::ValidationError,
              "schedule '#{@id}'.overrides: unknown key(s) #{unknown.inspect} " \
              "(allowed: #{OVERRIDE_KEYS.join(', ')})"
      end

      overrides.each do |key, value|
        # model is a provider/model REF — validated at declaration, not left
        # for model-resolution time; everything else is an integer ceiling.
        if key == "model"
          if !value.is_a?(String) || value.strip.empty?
            raise Insika::ValidationError,
                  "schedule '#{@id}'.overrides.model must be a non-blank String (a " \
                  "model ref), got: #{value.inspect}"
          end
          next
        end

        unless value.is_a?(Integer) && value.positive?
          raise Insika::ValidationError,
                "schedule '#{@id}'.overrides.#{key} must be a positive Integer, got: #{value.inspect}"
        end
      end

      overrides
    end
  end
end