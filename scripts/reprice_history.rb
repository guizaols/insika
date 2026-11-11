# frozen_string_literal: true

# Reprices the requests already in Studio's model history at what each provider
# billed for them. A request is recorded at the catalog rate of the moment, and
# that was wrong in two ways: a provider's peak hours were not priced (DeepSeek
# bills them at double, see Telemetry::PeakPricing), and the catalog trailed the
# provider's price list (deepseek-v4-pro until 2026-10-02). Each row's cost is
# recomputed from its own token counts, the provider's price list below and the
# hour the request ended in.
#
# It reports every provider and model it finds, with what it did about each:
# repriced it, left it because the provider itself reported the billed amount, or
# left it because no price list here covers it. Reports only, unless --apply.
# Running it twice changes nothing more, and it is safe with the app running.
# Uses the deployment's store (INSIKA_DB or INSIKA_DATABASE_URL), like the app, so
# run it on the host. It corrects the request rows and their day summaries, which
# is what Studio Home, Models and agent performance read; a task's own trace keeps
# the cost it recorded.
#
#   bundle exec ruby scripts/reprice_history.rb
#   bundle exec ruby scripts/reprice_history.rb --apply
#
# Every price list was checked against its source on 2026-11-10. If a provider has
# changed prices since, pass --until <ISO time> to stop at the change.
require "time"
require_relative "../lib/insika"

module Insika
  module RepriceHistory
    BUCKETS = %w[input cache_read cache_write output].freeze

    # USD per million tokens, by token bucket (`input` is uncached input), in force
    # from `from` on. Off-peak rates for a provider that bills by the hour.
    # `long_context` replaces the rates of a request whose whole prompt is larger
    # than `over` tokens.
    PRICE_BOOK = [
      # https://api-docs.deepseek.com/quick_start/pricing
      { "provider" => "deepseek", "from" => "2026-09-10T04:00:00Z",
        "models" => %w[deepseek-flash deepseek-v4-flash deepseek-v4-flash-vision-exp],
        "rates" => { "input" => 0.15, "cache_read" => 0.003, "output" => 0.6 } },
      { "provider" => "deepseek", "from" => "2026-09-10T04:00:00Z", "models" => %w[deepseek-v4-pro],
        "rates" => { "input" => 0.66, "cache_read" => 0.022, "output" => 1.98 } },
      # https://developers.openai.com/api/docs/pricing (standard tier; cache writes
      # at the default 30-minute lifetime, the only one Insika asks for)
      { "provider" => "openai", "from" => "2026-09-22T00:00:00Z", "models" => %w[gpt-6-luna],
        "rates" => { "input" => 0.1, "cache_read" => 0.01, "cache_write" => 0.125, "output" => 0.5 },
        "long_context" => { "over" => 272_000, "rates" => {
          "input" => 0.2, "cache_read" => 0.02, "cache_write" => 0.25, "output" => 0.75
        } } }
    ].freeze

    # Their responses carry the amount billed, and RubyLLM records that amount.
    REPORTED = %w[openrouter].freeze

    SINCE = PRICE_BOOK.map { |entry| Time.iso8601(entry["from"]) }.min

    module_function

    # -> what the provider billed for the row (USD), or nil when no price list
    # here covers it.
    def cost(row)
      rates = rates_for(row) or return nil
      return nil if BUCKETS.any? { |bucket| row["#{bucket}_tokens"].to_i.positive? && rates[bucket].nil? }

      base = rates.sum { |bucket, price| row["#{bucket}_tokens"].to_i * price } / 1_000_000.0
      base * Telemetry::PeakPricing.multiplier(row["provider"], Time.iso8601(row["completed_at"]))
    end

    def rates_for(row)
      return nil unless row["input_tokens"] && row["output_tokens"] && row["completed_at"]

      model = row["model"].to_s.delete_prefix("#{row['provider']}/")
      entry = PRICE_BOOK.find do |candidate|
        candidate["provider"] == row["provider"] && candidate["models"].include?(model) &&
          Time.iso8601(row["completed_at"]) >= Time.iso8601(candidate["from"])
      end
      return nil unless entry

      long = entry["long_context"] or return entry["rates"]
      return nil unless row["attempts"] == 1 # the tier is per attempt, and a retried row holds their sum

      prompt = %w[input cache_read cache_write].sum { |bucket| row["#{bucket}_tokens"].to_i }
      prompt > long["over"] ? long["rates"] : entry["rates"]
    end

    def status(row, billed)
      return "priced from the provider's price list" if billed
      return "left: the provider reported the billed amount" if REPORTED.include?(row["provider"])

      "left: no price list here covers it"
    end

    # -> [ModelMetricsStore#reprice's result,
    #     { [provider, model, status] => { rows:, peak:, before:, after: } }]
    def call(store:, to: Time.now.utc, apply: false)
      found = Hash.new { |hash, key| hash[key] = { rows: 0, peak: 0, before: 0.0, after: 0.0 } }
      result = store.reprice(from: SINCE, to: to, apply: apply) do |row|
        billed = cost(row)
        stats = found[[row["provider"], row["model"], status(row, billed)]]
        stats[:rows] += 1
        stats[:peak] += 1 if Telemetry::PeakPricing.multiplier(row["provider"], Time.iso8601(row["completed_at"])) > 1
        stats[:before] += row["cost"]
        stats[:after] += billed || row["cost"]
        billed
      end
      [result, found]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  unless %w[INSIKA_DB INSIKA_DATABASE_URL].any? { |name| !ENV[name].to_s.empty? }
    abort "INSIKA_DB or INSIKA_DATABASE_URL is required"
  end
  apply = ARGV.include?("--apply")
  till = ARGV.index("--until")&.then { |i| Time.iso8601(ARGV.fetch(i + 1)) } || Time.now.utc
  store = Insika::ModelMetricsStore.new(store: Insika::Wiring::Graph.raw_backend_from_env)
  result, found = Insika::RepriceHistory.call(store: store, to: till, apply: apply)

  puts "#{result['rows']} request rows from #{Insika::RepriceHistory::SINCE.iso8601} to #{till.iso8601}"
  found.sort_by { |key, _| key.map(&:to_s) }.each do |(provider, model, status), stats|
    puts format("  %-44s %8d rows, %d in peak hours  USD %.6f -> %.6f  %s", "#{provider}/#{model}", stats[:rows],
                stats[:peak], stats[:before], stats[:after], status)
  end
  puts format("%d rows %s: USD %.6f -> %.6f", result["changed"], apply ? "repriced" : "to reprice",
              result["before"], result["after"])
  puts "nothing written: pass --apply" unless apply
end
