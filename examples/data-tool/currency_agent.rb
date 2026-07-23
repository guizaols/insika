# frozen_string_literal: true

# data-tool — a tool defined as DATA, not code. `data_tool` declares an HTTP call
# with a JSON-Schema parameter list and a URL template; the running agent calls
# it in its tool-loop. No Ruby class, no rebuild — the tool is a row.
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/data-tool/currency_agent.rb "1 USD in BRL?"
require_relative "../../lib/insika"

fx = Insika.agent("fx") do
  model "deepseek-chat"
  provider :deepseek
  instructions <<~PROMPT
    You convert currencies. When the user asks about an exchange rate, call
    convert_currency with ISO-4217 codes (USD, BRL, EUR, …) and report the rate
    plainly. Do not invent rates.
  PROMPT

  # A declarative HTTP tool. `{{from}}` / `{{to}}` are the model-supplied params;
  # the insika substitutes them at call time. Public HTTPS endpoint, no API key.
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
    "request"  => {
      "method" => "GET",
      "url"    => "https://api.frankfurter.app/latest?from={{from}}&to={{to}}"
    },
    "response" => { "extract" => "body_raw" }
  )
end

message = ARGV.join(" ")
message = "how many BRL is 1 USD right now?" if message.empty?
puts fx.reply(message)
# => "Right now 1 USD is about 5.43 BRL (ECB reference rate for 2026-07-23)."
