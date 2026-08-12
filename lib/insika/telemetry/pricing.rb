# frozen_string_literal: true

require "json"

module Insika
  module Telemetry
    # Estimated cost of a turn, from a rates table given as DATA.
    #
    # Insika never ships prices: they change weekly, differ per contract and per
    # region, and a stale table in the engine would be worse than no number at all.
    # The operator declares the rates, Insika only multiplies — which is why the
    # attribute is documented as an ESTIMATE, not a bill.
    #
    # Rates are **USD per million tokens** (the unit every provider publishes):
    #
    #   { "deepseek-v4-flash" => { "input" => 0.27, "output" => 1.10,
    #                          "cached_input" => 0.07, "cache_write" => 0.34 } }
    #
    # A key matches the model id the provider reports, with or without the
    # `provider/` prefix (`deepseek/deepseek-v4-flash` and `deepseek-v4-flash` both hit the
    # entry above). An UNKNOWN model -> nil: a missing price is not a zero cost, so
    # nothing is emitted and the dashboard shows a gap instead of a lie.
    #
    # Token accounting (matches `Executor#usage_of`, which mirrors the providers):
    # `cached_tokens` is a SUBSET of `input_tokens`, `cache_creation_tokens` is not.
    #   - `cached_input` given -> cached tokens are billed at that rate and
    #     subtracted from the fresh input; absent -> they stay at the input rate.
    #   - `cache_write` given -> cache-creation tokens billed at that rate; absent
    #     -> at the input rate (they are input tokens the provider did write).
    class Pricing
      # 12 decimals: a single cheap turn can cost ~1e-6 USD, and rounding is only
      # here to keep float noise out of the exported attribute.
      PRECISION = 12

      # rates: Hash of model id -> Hash of rate name -> USD per million tokens.
      # Anything not shaped like that is ignored (a bad table degrades to "no cost",
      # never to a wrong number).
      def initialize(rates)
        @rates = normalize(rates)
      end

      def empty? = @rates.empty?

      # -> Float (USD) | nil when the model is absent/unpriced.
      def cost(usage)
        return nil if usage.nil?

        rate = rate_for(usage[:model]) or return nil

        input   = usage[:input_tokens].to_i
        cached  = usage[:cached_tokens].to_i
        written = usage[:cache_creation_tokens].to_i
        output  = usage[:output_tokens].to_i

        cached_rate = rate["cached_input"]
        fresh = cached_rate ? [input - cached, 0].max : input

        millionths = fresh * rate["input"].to_f +
                     (cached_rate ? cached * cached_rate.to_f : 0.0) +
                     written * (rate["cache_write"] || rate["input"]).to_f +
                     output * rate["output"].to_f
        (millionths / 1_000_000.0).round(PRECISION)
      end

      # Parses the operator's table. Accepts a JSON object; anything else (blank,
      # malformed, not an object) -> an EMPTY Pricing, never an exception: telemetry
      # config must not be able to stop a boot.
      def self.parse(json)
        return new({}) if json.nil? || json.to_s.strip.empty?

        parsed = JSON.parse(json.to_s)
        new(parsed.is_a?(Hash) ? parsed : {})
      rescue JSON::ParserError
        new({})
      end

      private

      # Indexes each entry under BOTH spellings (full id and the part after the
      # last "/") so a lookup is a single hash hit, never a scan.
      def normalize(rates)
        return {} unless rates.is_a?(Hash)

        rates.each_with_object({}) do |(model, rate), acc|
          next unless rate.is_a?(Hash)

          entry = rate.transform_keys(&:to_s)
          next unless entry["input"] || entry["output"]

          key = model.to_s
          acc[key] = entry
          acc[key.split("/").last] ||= entry
        end
      end

      def rate_for(model)
        key = model.to_s
        return nil if key.empty?

        @rates[key] || @rates[key.split("/").last]
      end
    end
  end
end
