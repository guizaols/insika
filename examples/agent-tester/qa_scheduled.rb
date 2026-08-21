# frozen_string_literal: true

# qa_scheduled — the QA loop in one file: a scheduled QA agent (RFC-0037) that
# runs an authored persona case against a SIBLING agent, in-process
# (`run_persona_eval`, C3.1), and publishes the verdict as an artifact
# (`save_artifact`, RFC-0038). The Simulator (A1) + the Scheduler (A2) + Artifacts
# (A3) in one flow — see docs/EVALS.md "run_persona_eval".
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/qa_scheduled.rb
#   DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/qa_scheduled.rb --serve
#       # --serve: open /studio, log in with the printed token, then send
#       # "Run QA now." to the "qa" agent in the Playground — the report lands
#       # on the Artifacts tab.
#
# 100% fake data: no real store name, no real customer, no real catalog.
require_relative "../../lib/insika"

system = Insika.system do
  # The TARGET agent — the one being tested. READ-ONLY on purpose:
  # run_persona_eval refuses a target with a reachable side-effect tool (no
  # swap is wired for an in-process run yet — see docs/EVALS.md).
  agent("assistant") do
    model "deepseek-v4-flash"
    provider :deepseek
    instructions <<~PROMPT
      You are a concise, friendly gift-shopping assistant. Ask what you need to
      know (budget, occasion, who it's for) BEFORE searching, then recommend
      real options from the catalog and close with a next step.
    PROMPT

    data_tool(
      "name" => "search_products",
      "description" => "Search the catalog. Params: q (query), max_price (optional).",
      "parameters" => {
        "type" => "object", "additionalProperties" => false, "required" => ["q"],
        "properties" => {
          "q" => { "type" => "string", "description" => "The search query" },
          "max_price" => { "type" => "number", "description" => "Optional price ceiling" }
        }
      },
      "request" => {
        "method" => "GET",
        "url" => "https://example.invalid/catalog?q={{q}}&max_price={{max_price}}"
      },
      "response" => { "extract" => "body_raw" }
    )
  end

  # The QA agent. `tools` is the ONLY thing that gives it run_persona_eval +
  # save_artifact — nothing global enables either.
  agent("qa") do
    model "deepseek-v4-flash"
    provider :deepseek
    instructions <<~PROMPT
      You are the quality-assurance agent for the "assistant" agent. When asked
      to run QA: call run_persona_eval with the one case you have, then publish
      a short HTML report (verdict, score, reason, and the transcript) with
      save_artifact. Never name a tool in the report text. Stop right after
      the artifact is published.
    PROMPT
    tools %w[run_persona_eval save_artifact]

    # The recurring half (RFC-0037) — the engine's tick fires it. A weekly
    # cadence is a reasonable default for a report this cheap (one persona
    # turn + one judge call); see docs/EVALS.md for the cost shape.
    schedule "weekly_qa", cron: "0 9 * * 1", tz: "America/Sao_Paulo",
             message: "Run QA now.", session_mode: "new",
             overrides: { turn_timeout: 300, max_tool_calls: 20 }
  end
end

runtime = system.runtime

# Seed the persona case this example ships with — the SAME shape
# `evals:simulate` and the Studio's Evals page both read (GoldenStore, scope
# "goldens"). Public demo data only.
Insika::GoldenStore.new(config_store: runtime.component(:config_store)).write(
  { "id" => "qa-demo-01", "agent" => "assistant",
    "persona" => {
      "goal" => "find a gift under R$100 for a birthday; doesn't know product names",
      "style" => "short messages, answers what they ask, gives up if asked to explain twice",
      "opens_with" => "oi, queria um presente",
      "knows" => { "budget" => "100", "occasion" => "birthday" }, "max_turns" => 6
    },
    "expect" => {
      "policy" => "investigate_first",
      "rubric" => "Establishes the objective before recommending (one or two questions, " \
                 "not a form), recommends real options within budget and closes with a " \
                 "clear next step. Fails if it dumps the catalog before understanding, " \
                 "or keeps asking without ever searching.",
      "min_score" => 0.7
    } }
)

if ARGV.include?("--serve")
  system.serve(port: 9292, host: "0.0.0.0", token: "local-demo")
else
  puts system.reply("qa", "Run QA now.")
  puts "\nThen open the returned /studio/artifacts/<id> page (or --serve and look at the Artifacts tab)."
end
