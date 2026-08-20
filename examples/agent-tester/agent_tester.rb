# frozen_string_literal: true

# agent-tester — simulate a customer against your own agent (RFC-0014 PR2).
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/agent_tester.rb
#
# Runs a SIMULATED conversation: a persona model (the cheap utility_model) plays a
# customer whose ONLY facts are the persona's `knows`; the `assistant` agent answers
# in-process (GraphTransport — the local graph, no server). Prints the transcript and
# the judge's verdict on the whole conversation.
#
# SAFETY: a simulated run must not write for real, so the agent below has NO
# side-effect tool (search_products is a read). The Simulator derives the side-effect
# list from the tool registry and refuses to run if any reachable tool can write —
# unless you declare the target staging or use an eval profile. See docs/EVALS.md.
require_relative "../../lib/insika"

# A persona file is the same YAML a golden carries: a `persona:` key instead of
# `turns:`, plus the `expect:` the judge scores against. Public demo persona —
# brand-free, exercises a discovery flow (the `investigate_first` policy).
PERSONA = {
  "id" => "agent-tester-objetivo-difuso",
  "agent" => "assistant",
  "persona" => {
    "goal" => "find a gift under R$100 for a birthday; doesn't know product names",
    "style" => "short messages, answers what they ask, gives up if asked to explain twice",
    "opens_with" => "oi, queria um presente",
    "knows" => { "budget" => "100", "occasion" => "birthday" },
    "max_turns" => 8
  },
  "expect" => {
    "policy" => "investigate_first",
    "rubric" => <<~RUBRIC,
      Establishes the objective before recommending (one or two questions, not a form),
      recommends real products within budget and closes with a clear next step. Fails
      if it dumps the catalog before understanding, or keeps asking without ever searching.
    RUBRIC
    "min_score" => 0.7
  }
}.freeze

assistant = Insika.agent("assistant") do
  model "deepseek-v4-flash"
  provider :deepseek
  instructions <<~PROMPT
    You are a concise, friendly gift-shopping assistant. Ask what you need to know
    (budget, occasion, who it's for) BEFORE searching, then recommend real options
    from the catalog and close with a next step.
  PROMPT

  # READ-ONLY tool — a data-defined tool whose GET method is NOT a side effect. If
  # this were a POST (write), the Simulator would refuse to run it without staging.
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

runtime = assistant.runtime
profile = runtime.profile("assistant")
registry = runtime.graph.tool_registry

# The DERIVED side-effect list — computed from the registry, never hand-maintained.
side_effect = Insika::Evals::EvalProfile.side_effect_tools(profile, registry)
abort "the example agent must be read-only; found side-effect tools: #{side_effect.join(', ')}" unless side_effect.empty?

transport = Insika::Evals::GraphTransport.new(runtime: runtime)
ask = Insika::Evals::JudgePanel.ruby_llm_ask(ENV["EVAL_PERSONA_MODEL"] || "deepseek-v4-flash", :deepseek)
sim = Insika::Evals::Simulator.new(
  transport: transport, ask: ask,
  safety: Insika::Evals::Simulator::Safety.new(side_effect_tools: side_effect)
)

golden = Insika::Evals::GoldenLoader.build(PERSONA, source: "examples/agent-tester/persona.yml")
run = sim.run(persona: golden.persona, agent: golden.agent, conv: "agent-tester-demo")
verdict = Insika::Evals::Judge.new(ask: Insika::Evals::JudgePanel.ruby_llm_ask("deepseek-v4-flash", :deepseek))
            .score_conversation(rubric: golden.rubric, transcript: run.transcript,
                                policy: golden.policy, min_score: golden.min_score)

puts "# Agent-tester — simulated conversation"
puts "stop: #{run.stop} · turns: #{run.turns} · simulated: #{run.simulated}"
run.transcript.each do |m|
  role = m[:role].to_s == "user" ? "customer" : "assistant"
  puts "\n#{role}: #{m[:text]}"
end
if verdict
  puts "\njudge: #{verdict.pass ? 'PASS' : 'FAIL'} #{verdict.score} — #{verdict.reason}"
end
exit(run.stop == :error || (verdict && !verdict.pass) ? 1 : 0)