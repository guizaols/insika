# frozen_string_literal: true

# ---
# title: Travel Planner
# trail: Starter
# description: Weather + currency data-tools against keyless public APIs (Open-Meteo, Frankfurter) — the egress guard does its job with zero configuration.
# capabilities: data-tool, egress-guard
# ---
#
# travel-planner — plans a trip: geocodes the destination, checks today's
# weather, and converts a budget to the local currency. Three declarative
# data-tools, no Ruby tool class, no API key beyond the LLM provider's.
#
#   DEEPSEEK_API_KEY=sk-... ruby travel-planner/agent.rb "3 days in Lisbon, budget 200 USD"
#   DEEPSEEK_API_KEY=sk-... ruby travel-planner/agent.rb --serve
require "insika"

travel = Insika.agent("travel-planner") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You are a travel-planning assistant. Given a destination and, optionally,
    a budget amount + currency:
      1. geocode_city to find its coordinates — never guess them.
      2. get_weather for those coordinates and summarize today's conditions.
      3. If a budget was given, convert_currency to the destination's local
         currency and report the converted amount.
    Never invent coordinates, weather or exchange rates — always call the tools.
  PROMPT

  data_tool(
    "name"        => "geocode_city",
    "description" => "Latitude/longitude for a city name (Open-Meteo geocoding).",
    "parameters"  => {
      "type" => "object",
      "properties" => { "city" => { "type" => "string", "description" => "city name, e.g. Lisbon" } },
      "required" => ["city"]
    },
    "request"  => { "method" => "GET", "url" => "https://geocoding-api.open-meteo.com/v1/search?name={{city}}&count=1" },
    "response" => { "extract" => "body_raw" }
  )

  data_tool(
    "name"        => "get_weather",
    "description" => "Current weather for a latitude/longitude (Open-Meteo).",
    "parameters"  => {
      "type" => "object",
      "properties" => {
        "latitude"  => { "type" => "number", "description" => "from geocode_city" },
        "longitude" => { "type" => "number", "description" => "from geocode_city" }
      },
      "required" => %w[latitude longitude]
    },
    "request"  => { "method" => "GET", "url" => "https://api.open-meteo.com/v1/forecast?latitude={{latitude}}&longitude={{longitude}}&current_weather=true" },
    "response" => { "extract" => "body_raw" }
  )

  # Author the FINAL url — the HTTP client does not follow redirects.
  # api.frankfurter.app now redirects to api.frankfurter.dev.
  data_tool(
    "name"        => "convert_currency",
    "description" => "Latest reference exchange rate between two currencies.",
    "parameters"  => {
      "type" => "object",
      "properties" => {
        "from" => { "type" => "string", "description" => "source currency code, e.g. USD" },
        "to"   => { "type" => "string", "description" => "target currency code, e.g. BRL" }
      },
      "required" => %w[from to]
    },
    "request"  => { "method" => "GET", "url" => "https://api.frankfurter.dev/v1/latest?from={{from}}&to={{to}}" },
    "response" => { "extract" => "body_raw" }
  )
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    travel.serve
  else
    message = ARGV.join(" ")
    message = "I'm spending 3 days in Lisbon with a budget of 200 USD. What should I pack, and how much is that in EUR?" if message.empty?
    puts travel.reply(message)
  end
end

travel
