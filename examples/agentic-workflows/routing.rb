# frozen_string_literal: true

# ROUTING — classify the request, then hand it to the right specialist.
#
#   run: DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/routing.rb
#
# One cheap classification turn buys specialists with short, focused prompts
# instead of one agent carrying every instruction it might ever need.

require "insika"

support = Insika.system do
  provider :deepseek

  agent "router" do
    model "deepseek-chat"
    # A classifier is not a chat: constrain the output to the label set.
    instructions "Classify the message. Reply with EXACTLY one word: billing, technical, or other."
  end

  agent "billing" do
    model "deepseek-chat"
    instructions "You handle billing issues. Answer in at most 3 sentences, warm and concrete."
  end

  agent "technical" do
    model "deepseek-chat"
    instructions "You handle technical issues. Answer in at most 3 sentences, concrete steps only."
  end

  agent "generalist" do
    model "deepseek-chat"
    instructions "You are a helpful support agent. Answer in at most 3 sentences."
  end

  workflow "handle",
           description: "Routes a support message to a specialist.",
           input: { type: "object", properties: { message: { type: "string" } }, required: ["message"] } do |input, ctx|
    label = ctx.ask("router", input["message"]).to_s.downcase

    # The routing decision is RUBY, not a prompt: the label set is closed and an
    # unexpected answer falls back instead of picking a random branch.
    lane = if label.include?("billing")        then "billing"
           elsif label.include?("technical")   then "technical"
           else "generalist"
           end

    { "lane" => lane, "answer" => ctx.ask(lane, input["message"]) }
  end
end

[
  "You charged my card twice this month and I want a refund.",
  "The webhook retries forever and my endpoint returns 500."
].each do |message|
  result = support.run("handle", input: { "message" => message })
  puts "→ #{message}"
  puts "  lane:   #{result['lane']}"
  puts "  answer: #{result['answer'].to_s.lines.first.to_s.strip}"
  puts
end

puts "2 turns per request: one to decide, one to answer — and the fallback is code."
