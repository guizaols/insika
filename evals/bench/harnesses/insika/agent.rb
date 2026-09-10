# frozen_string_literal: true

# OUR ENTRY. Same store over MCP, same model, same AGENTS.md every other harness is
# given — one embedded turn per process, exactly as `openclaw agent --local` is.
#
# Two configurations, because the bench has two scorecards and it would be worthless
# if ours were the only row that did not change between them:
#
#   A — parity. The model, the prompt, the store's ten tools, and nothing of ours.
#       Even `tool_persistence`, the engine's one default-ON prompt block, is off:
#       it is our layer, and a parity row that carries it is not a parity row.
#   B — out of the box. What a store deployment actually declares: which of the
#       server's answers are evidence and which parameter may only ever carry an id
#       the customer was shown, and third-party text treated as data.
#
# Nothing here is bench-specific engine behaviour: it is the DSL any deployment uses.
require "insika"

BENCH_SCORECARD = ENV.fetch("BENCH_SCORECARD", "A").upcase

BENCH = Insika.agent("bench") do
  model ENV.fetch("BENCH_MODEL", "deepseek/deepseek-v4-flash")
  provider :openrouter
  # The reasoning effort production runs, and the one every entrant in this bench
  # is set to. Left unset it is the provider's default, which is not the same
  # default in six different clients — and the table would read that as a harness
  # difference.
  param :thinking, ENV.fetch("BENCH_REASONING", "medium")

  instructions File.read(ENV.fetch("BENCH_PROMPT", "/prompt/AGENTS.md"))

  if BENCH_SCORECARD == "B"
    # Third-party text is data, never instructions — a store's tool output is
    # third-party text.
    fencing true

    # What the deployment trusts each tool with. The server describes what its tools
    # DO; only we can say which of its answers are evidence and which parameter may
    # only ever carry an id the customer was actually shown.
    mcp "store", transport: :http, url: ENV.fetch("BENCH_STORE_MCP"),
        tools: {
          "search_products" => { evidence: { kind: "products", items: "products",
                                             id: "product_id", line: "line" } },
          "view_cart" => { evidence: { kind: "cart", items: "items",
                                       id: "product_id", line: "line" } },
          "add_to_cart" => { requires_evidence: ["product_id"] }
        }
  else
    tool_persistence false
    mcp "store", transport: :http, url: ENV.fetch("BENCH_STORE_MCP")
  end
end
