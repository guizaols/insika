# frozen_string_literal: true

module Insika
  # IANA timezone handling through the OS tz database — the
  # engine's only route to a zone NAME (Ruby stdlib's `Time#getlocal` takes an
  # offset, not a zone name). Shared by FollowupPolicy (quiet hours), the cron
  # parser (next-fire materialization) and the doctor (zone existence).
  #
  # IANA names are resolved by pointing Ruby's `TZ` at the zone for the
  # computation. Save/restore keeps the global intact; under the engine's
  # cooperative fiber model — no IO between the save and the restore — the
  # mutation is atomic on the calling fiber.
  module Timezone
    # The candidate tz-data roots (TZDIR first — Ruby's own lookup env). The
    # zone name maps to a FILE under the root ("America/Sao_Paulo" ->
    # "America/Sao_Paulo").
    TZ_ROOTS = ([ENV["TZDIR"]] +
                %w[/usr/share/zoneinfo /usr/share/lib/zoneinfo /etc/zoneinfo])
               .compact.freeze

    module_function

    # -> bool: is `zone` an IANA name the OS tz database knows? A bogus zone
    # is a malformed declaration — refused where the doctor can name it (an
    # unknown ENV["TZ"] silently behaves as UTC, so existence is checked
    # against the database, not by asking Time).
    def known?(zone)
      zone = zone.to_s
      return true if zone == "UTC" || zone == "Etc/UTC"

      TZ_ROOTS.any? { |root| File.directory?(root) && File.exist?(File.join(root, zone)) }
    end

    # Yields `time` interpreted in the given IANA zone (via a save/restore of
    # ENV["TZ"] — the stdlib-only route to the OS tz database). Returns the
    # block's value.
    def in_zone(zone, time)
      previous = ENV["TZ"]
      ENV["TZ"] = zone.to_s
      yield time
    ensure
      ENV["TZ"] = previous
    end
  end
end