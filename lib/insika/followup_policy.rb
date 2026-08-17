# frozen_string_literal: true

module Insika
  # RFC-0033 C2: the parsed follow-up policy of ONE agent — the ONLY shape the
  # engine accepts, shared by the schedule/cancel tools, the FollowupEngine,
  # the doctor and the Studio. Pure value object: it never touches a store
  # (D8 — the policy is pack data on the profile, no platform settings layer).
  #
  # `parse` returns nil on a malformed hash (D9 — the firer BLOCKS, the doctor
  # explains, the tools refuse); `parse!` raises Insika::ValidationError naming
  # the exact defect.
  class FollowupPolicy
    QuietHours = Data.define(:timezone, :start, :end)

    FREQUENCY_RE = /\A(\d+)\/(\d+)(m|h|d)s?\z/
    HH_MM_RE     = /\A\d{2}:\d{2}\z/
    DEFAULT_ARM = "schedule"
    DEFAULT_SILENCE_AFTER_SENDS = 3
    KEYWORD_MAX = 200

    attr_reader :arm, :quiet_hours, :max_frequency, :cancel_keywords, :silence_after_sends

    def self.parse(hash)
      new(hash)
    rescue Insika::ValidationError
      nil
    end

    def self.parse!(hash)
      new(hash)
    end

    def initialize(hash)
      raise Insika::ValidationError, "followup: declaration must be a Hash" unless hash.is_a?(Hash)

      h = hash.transform_keys(&:to_s)
      @arm = arm_of(h)
      policy = h["policy"]
      raise Insika::ValidationError, "followup.policy must be a Hash" unless policy.is_a?(Hash)

      policy = policy.transform_keys(&:to_s)
      @quiet_hours = quiet_hours_of(policy)
      @max_frequency = frequency_of(policy)
      @cancel_keywords = keywords_of(policy)
      @silence_after_sends = silence_of(policy)
      freeze
    end

    # "2/24h" -> { count: 2, seconds: 86_400 }. nil when the policy has no
    # ceiling (absent max_frequency — the frequency gate is off). Always valid
    # once parsed.
    # `count` is the sends allowed per window; `seconds` is the WINDOW's
    # duration (the value after the "/"), never count*window.
    def frequency_window
      return nil if @max_frequency.nil?

      match = FREQUENCY_RE.match(@max_frequency)
      multiplier = { "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(match[3])
      { count: match[1].to_i, seconds: match[2].to_i * multiplier }
    end

    # Is the given UTC Time inside quiet hours in the policy's timezone? (nil
    # quiet_hours -> false: no quiet window.)
    #
    # IANA names are resolved through the OS tz database by pointing Ruby's
    # `TZ` at the zone for the computation (Ruby stdlib's `Time#getlocal`
    # only takes an offset, not a zone name). Save/restore keeps the global
    # intact; under the engine's cooperative fiber model — no IO between the
    # save and the restore — the mutation is atomic on the calling fiber.
    def quiet?(time)
      return false unless @quiet_hours

      local = in_zone(@quiet_hours.timezone, time) { |t| t.getlocal }
      minutes = local.hour * 60 + local.min
      start_min = minutes_of(@quiet_hours.start)
      end_min = minutes_of(@quiet_hours.end)
      if start_min <= end_min
        minutes >= start_min && minutes < end_min
      else
        # an overnight window: 21:30-09:00
        minutes >= start_min || minutes < end_min
      end
    end

    # The first cancel keyword matched (case/accent-insensitive substring);
    # nil when none matches.
    def match_keyword(text)
      folded = fold(text)
      @cancel_keywords.each do |kw|
        return kw if folded.include?(fold(kw))
      end
      nil
    end

    def to_h
      { "arm" => @arm,
        "policy" => {
          "quiet_hours" => @quiet_hours && {
            "timezone" => @quiet_hours.timezone, "start" => @quiet_hours.start, "end" => @quiet_hours.end
          },
          "max_frequency" => @max_frequency,
          "cancel_keywords" => @cancel_keywords,
          "silence_after_sends" => @silence_after_sends
        }.compact }
    end

    private

    def arm_of(hash)
      arm = hash["arm"]
      return DEFAULT_ARM if arm.nil?

      arm = arm.to_s
      raise Insika::ValidationError, "followup.arm must be a non-blank String" if arm.strip.empty?

      arm
    end

    def quiet_hours_of(policy)
      qh = policy["quiet_hours"]
      return nil if qh.nil?

      raise Insika::ValidationError, "followup.policy.quiet_hours must be a Hash" unless qh.is_a?(Hash)

      qh = qh.transform_keys(&:to_s)
      timezone = qh["timezone"]
      raise Insika::ValidationError, "followup.policy.quiet_hours.timezone is required" if Coercion.blank?(timezone)

      start_at = qh["start"]
      end_at = qh["end"]
      unless HH_MM_RE.match?(start_at.to_s) && HH_MM_RE.match?(end_at.to_s)
        raise Insika::ValidationError,
              "followup.policy.quiet_hours.start/end must match /\\A\\d{2}:\\d{2}\\z/ (24h)"
      end

      # a bogus IANA zone is a malformed policy — refused HERE, where the
      # doctor can name it. An unknown ENV["TZ"] silently behaves as UTC, so
      # existence is checked against the OS tz database, not by asking Time.
      unless zone_known?(timezone.to_s)
        raise Insika::ValidationError,
              "followup.policy.quiet_hours.timezone is not a valid IANA timezone: #{timezone.inspect}"
      end
      QuietHours.new(timezone: timezone.to_s, start: start_at.to_s, end: end_at.to_s)
    end

    def frequency_of(policy)
      f = policy["max_frequency"]
      return nil if f.nil?

      f = f.to_s
      unless FREQUENCY_RE.match?(f)
        raise Insika::ValidationError,
              "followup.policy.max_frequency must match /\\A\\d+\\/(\\d+)(m|h|d)s?\\z/ (e.g. \"2/24h\"; weeks are not allowed)"
      end

      f
    end

    def keywords_of(policy)
      list = policy["cancel_keywords"]
      return [] if list.nil?

      raise Insika::ValidationError, "followup.policy.cancel_keywords must be an Array" unless list.is_a?(Array)

      list.map!(&:to_s)
      list.each do |kw|
        if Coercion.blank?(kw)
          raise Insika::ValidationError, "followup.policy.cancel_keywords: each keyword must be non-blank"
        end
        if kw.length > KEYWORD_MAX
          raise Insika::ValidationError,
                "followup.policy.cancel_keywords: each keyword must be <= #{KEYWORD_MAX} chars"
        end
      end
      list
    end

    def silence_of(policy)
      s = policy["silence_after_sends"]
      return DEFAULT_SILENCE_AFTER_SENDS if s.nil?

      raise Insika::ValidationError, "followup.policy.silence_after_sends must be an Integer > 0" unless s.is_a?(Integer) && s.positive?

      s
    end

    # NFD + strip combining marks + downcase: the same fold the doctor's
    # identity matcher uses, so "NÃO" matches "não".
    def fold(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
    end

    # Yields `time` interpreted in the given IANA zone (via a save/restore of
    # ENV["TZ"] — the stdlib-only route to the OS tz database; see #quiet?).
    def in_zone(zone, time)
      previous = ENV["TZ"]
      ENV["TZ"] = zone
      yield time
    ensure
      ENV["TZ"] = previous
    end

    # The candidate tz-data roots (TZDIR first — Ruby's own lookup env). The
    # zone name maps to a FILE under the root ("America/Sao_Paulo" ->
    # "America/Sao_Paulo").
    TZ_ROOTS = ([ENV["TZDIR"]] +
                %w[/usr/share/zoneinfo /usr/share/lib/zoneinfo /etc/zoneinfo])
               .compact.freeze

    def zone_known?(zone)
      return true if zone == "UTC" || zone == "Etc/UTC"

      TZ_ROOTS.any? { |root| File.directory?(root) && File.exist?(File.join(root, zone)) }
    end

    def minutes_of(hhmm)
      h, m = hhmm.split(":").map(&:to_i)
      h * 60 + m
    end
  end
end
