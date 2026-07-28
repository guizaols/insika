# frozen_string_literal: true

# EVALUATOR-OPTIMIZER — produce, judge, revise until it passes (or give up).
#
#   run: DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/evaluator.rb
#
# The loop is a Ruby `while`, so the two things that matter are guaranteed by code
# and not by a prompt: the attempt CAP (a loop asking a model when to stop can run
# forever) and the honest report of whether it actually passed.

require "insika"

MAX_ATTEMPTS = 3

studio = Insika.system do
  provider :deepseek

  agent "copywriter" do
    model "deepseek-chat"
    instructions "Write a product tagline. Output ONLY the tagline, no quotes, no commentary."
  end

  agent "critic" do
    model "deepseek-chat"
    # A judge must answer in a form code can branch on.
    instructions <<~P
      Judge the tagline against the brief. Reply in EXACTLY this shape:
        VERDICT: PASS|FAIL
        REASON: <one short sentence>
      PASS only if it is under 8 words, concrete, and free of buzzwords
      ("revolutionary", "seamless", "next-generation", "empower").
    P
  end

  workflow "polish",
           description: "Writes a tagline and revises it until the critic passes it.",
           input: { type: "object", properties: { brief: { type: "string" } }, required: ["brief"] },
           output: { type: "object", properties: { tagline: { type: "string" },
                                                  passed: { type: "boolean" },
                                                  attempts: { type: "integer" } } } do |input, ctx|
    brief = input["brief"]
    tagline = ctx.ask("copywriter", brief)
    attempts = 1
    passed = false
    log = []

    loop do
      verdict = ctx.ask("critic", "Brief: #{brief}\nTagline: #{tagline}")
      passed = verdict.include?("PASS")
      log << { "attempt" => attempts, "tagline" => tagline, "verdict" => verdict.lines.first.to_s.strip }
      break if passed || attempts >= MAX_ATTEMPTS

      # The critic's REASON is the revision instruction — the feedback loop is
      # what makes this different from just asking twice.
      tagline = ctx.ask("copywriter", "Brief: #{brief}\nPrevious: #{tagline}\nFix this: #{verdict}")
      attempts += 1
    end

    { "tagline" => tagline, "passed" => passed, "attempts" => attempts, "log" => log }
  end
end

result = studio.run("polish", input: { "brief" => "A Ruby runtime for LLM agents in production." })

result["log"].each { |e| puts "attempt #{e['attempt']}: #{e['tagline']}  → #{e['verdict']}" }
puts
puts "final:    #{result['tagline']}"
puts "passed:   #{result['passed']} after #{result['attempts']} attempt(s), cap #{MAX_ATTEMPTS}"
puts
puts "The cap is code. A loop that asks the model when to stop can run forever."
