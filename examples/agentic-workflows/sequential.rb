# frozen_string_literal: true

# SEQUENTIAL (prompt chaining) — each step's output is the next step's input.
#
#   run: DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/sequential.rb
#
# The chain is Ruby, not a prompt: the order is in the code, so it is the same on
# every run. Use this shape when you already know the steps.

require "insika"

newsroom = Insika.system do
  provider :deepseek

  agent "writer" do
    model "deepseek-chat"
    instructions "Write ONE paragraph on the topic. Plain prose, no headings, no preamble."
  end

  agent "editor" do
    model "deepseek-chat"
    instructions "Rewrite the text as ONE sentence under 25 words. Output ONLY that sentence."
  end

  agent "translator" do
    model "deepseek-chat"
    instructions "Translate to Brazilian Portuguese. Output ONLY the translation."
  end

  # `input:` is a JSON Schema. A request that does not conform is refused BEFORE
  # any run exists — over HTTP that is a 422, here it raises.
  workflow "publish",
           description: "Draft a paragraph, tighten it to one sentence, translate it.",
           input: { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] },
           output: { type: "object",
                     properties: { headline: { type: "string" }, pt_br: { type: "string" } } } do |input, ctx|
    draft    = ctx.ask("writer",     "Topic: #{input['topic']}")
    headline = ctx.ask("editor",     draft)
    { "headline" => headline, "pt_br" => ctx.ask("translator", headline) }
  end
end

result = newsroom.run("publish", input: { "topic" => "why Ruby fibers suit LLM agents" })

puts "headline: #{result['headline']}"
puts "pt-BR:    #{result['pt_br']}"
puts
puts "3 agent turns, always in this order — the sequence is code, not a suggestion."
