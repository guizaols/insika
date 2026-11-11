# frozen_string_literal: true

module Insika
  module Telemetry
    # What a provider's peak hours add to the catalog price.
    #
    # RubyLLM's catalog holds one price per model and no clock. A provider that
    # bills by the hour (DeepSeek: twice the off-peak rate during peak hours) is
    # under-reported by half during its peak unless the hour is priced too.
    #
    # RULES is data, one entry per provider that bills by the clock, and holds no
    # price: the catalog rate is the off-peak one, and `multiplier` applies inside
    # `windows` (start inclusive, end exclusive, wall clock at `utc_offset`) on
    # `weekdays` (0 = Sunday; absent = every day), except on `holidays` (dates at
    # `utc_offset`).
    #
    # The instant that decides is the one the request ENDS at. DeepSeek's price
    # list does not say which instant counts and its usage reports no tier; its
    # 2025 off-peak discount was explicit ("the completion timestamp of each
    # request determines its pricing tier"), so that rule is kept.
    #
    # `holidays` are the days off in China's State Council schedule, published one
    # year at a time. Past the last listed year a holiday on a weekday is priced as
    # peak, and `insika doctor` says so: add the year when it is published.
    module PeakPricing
      RULES = {
        # https://api-docs.deepseek.com/quick_start/pricing
        "deepseek" => {
          "multiplier" => 2,
          "utc_offset" => "+08:00",
          "weekdays" => [1, 2, 3, 4, 5],
          "windows" => [%w[09:00 12:00], %w[14:00 18:00]],
          "holidays" => %w[
            2026-01-01 2026-01-02 2026-01-03
            2026-02-15 2026-02-16 2026-02-17 2026-02-18 2026-02-19 2026-02-20 2026-02-21 2026-02-22 2026-02-23
            2026-04-04 2026-04-05 2026-04-06
            2026-05-01 2026-05-02 2026-05-03 2026-05-04 2026-05-05
            2026-06-19 2026-06-20 2026-06-21
            2026-09-25 2026-09-26 2026-09-27
            2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06 2026-10-07
            2027-01-01 2027-01-02 2027-01-03
            2027-02-05 2027-02-06 2027-02-07 2027-02-08 2027-02-09 2027-02-10 2027-02-11 2027-02-12 2027-02-13
            2027-04-03 2027-04-04 2027-04-05
            2027-05-01 2027-05-02 2027-05-03 2027-05-04 2027-05-05
            2027-06-09
            2027-09-15
            2027-10-01 2027-10-02 2027-10-03 2027-10-04 2027-10-05 2027-10-06 2027-10-07
          ].freeze
        }.freeze
      }.freeze

      module_function

      # -> the multiplier in force for `provider` at `at`: 1 outside its peak
      # hours, and for a provider that does not bill by the clock.
      def multiplier(provider, at = Time.now)
        rule = RULES[provider.to_s]
        rule && peak?(rule, at) ? rule["multiplier"] : 1
      end

      # -> the cost at the rate in force at `at`. An unknown cost stays unknown.
      def apply(cost, provider:, at: Time.now)
        cost.is_a?(Numeric) ? cost * multiplier(provider, at) : cost
      end

      def peak?(rule, at)
        local = at.getlocal(rule["utc_offset"])
        return false if rule["weekdays"] && !rule["weekdays"].include?(local.wday)
        return false if Array(rule["holidays"]).include?(local.strftime("%F"))

        clock = local.strftime("%H:%M")
        rule["windows"].any? { |from, to| clock >= from && clock < to }
      end

      # -> { provider => last year its holiday list covers }, for the rules that
      # have one.
      def holidays_through
        RULES.filter_map do |provider, rule|
          last = Array(rule["holidays"]).max
          [provider, last[0, 4].to_i] if last
        end.to_h
      end
    end
  end
end
