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

# The bisection this file also serves: cut 3 found phantom `add_to_cart` claims only
# in scorecard B, task 10, never in A. B differs from A in exactly three ways — set
# below to whichever the environment says, default = B unchanged — so a `BENCH_B_*`
# var can drop ONE of them per run and the phantom either follows it or doesn't.
# None of this touches what a real deployment declares; it exists to answer one
# question about this bench's own B row.
b_fencing = ENV.fetch("BENCH_B_FENCING", "true") == "true"
b_evidence = ENV.fetch("BENCH_B_EVIDENCE", "true") == "true"
b_persistence = ENV.fetch("BENCH_B_PERSISTENCE", "true") == "true"
# The customer-confirmation experiment's ONE variable. Default = today's B, so a
# cut that does not set it is the row the published cuts already carry.
b_confirmation = ENV.fetch("BENCH_B_CONFIRMATION", "true") == "true"
# Which OpenRouter upstream serves the model. Unset = whatever the gateway routes
# to that minute, which is what every cut so far measured; set, the two arms of an
# A/B cannot differ by the upstream they happened to land on.
b_provider = ENV["BENCH_PROVIDER"].to_s.strip

BENCH = Insika.agent("bench") do
  model ENV.fetch("BENCH_MODEL", "deepseek/deepseek-v4-flash")
  provider :openrouter
  # The reasoning effort production runs, and the one every entrant in this bench
  # is set to. Left unset it is the provider's default, which is not the same
  # default in six different clients — and the table would read that as a harness
  # difference.
  param :thinking, ENV.fetch("BENCH_REASONING", "medium")
  param :provider_routing, { "order" => [b_provider], "allow_fallbacks" => false } unless b_provider.empty?

  instructions File.read(ENV.fetch("BENCH_PROMPT", "/prompt/AGENTS.md"))

  if BENCH_SCORECARD == "B"
    # Third-party text is data, never instructions — a store's tool output is
    # third-party text. (b_fencing off = the bisection's "what if not")
    fencing true if b_fencing
    tool_persistence false unless b_persistence
    # Closing the order is the one write the customer cannot take back, so the
    # deployment holds it for their word: the model proposes, the engine records
    # the hold, the reply asks, and the next message confirms or cancels it.
    # (b_confirmation off = the same deployment without the hold, which is the
    # other arm of the confirmation experiment and nothing else.)
    customer_confirm "create_order" if b_confirmation

    # What the deployment trusts each tool with. The server describes what its tools
    # DO; only we can say which of its answers are evidence and which parameter may
    # only ever carry an id the customer was actually shown. (b_evidence off = the
    # plain MCP declaration, same shape as A's.)
    if b_evidence
      mcp "store", transport: :http, url: ENV.fetch("BENCH_STORE_MCP"),
          tools: {
            "search_products" => { evidence: { kind: "products", items: "products",
                                               id: "product_id", line: "line" } },
            "view_cart" => { evidence: { kind: "cart", items: "items",
                                         id: "product_id", line: "line" } },
            "add_to_cart" => { requires_evidence: ["product_id"] }
          }
    else
      mcp "store", transport: :http, url: ENV.fetch("BENCH_STORE_MCP")
    end
  else
    tool_persistence false
    mcp "store", transport: :http, url: ENV.fetch("BENCH_STORE_MCP")
  end
end
