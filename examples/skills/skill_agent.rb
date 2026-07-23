# frozen_string_literal: true

# skills — progressive skill loading. A skill is a named playbook. The agent sees
# only its name + description up front (cheap); it loads the full body on demand
# via the built-in load_skill tool, only when a turn actually needs it.
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/skills/skill_agent.rb "refund order #4471"
require_relative "../../lib/harness"

support = Harness.agent("support") do
  model "deepseek-chat"
  provider :deepseek
  instructions <<~PROMPT
    You are a customer-support agent. When a situation matches one of your
    skills, load it and follow it exactly before replying.
  PROMPT

  # The body is only pulled into context when the model loads it (Level 2).
  # Up front the agent knows just the name + description (Level 1).
  skill "refunds",
        description: "How to handle a refund request",
        instructions: <<~MD
          When a customer asks for a refund:
          1. If you don't have the order number, ask for it first.
          2. Confirm the purchase is within the 30-day return window.
          3. Offer store credit first; do a card refund only if they decline.
          Never promise a refund before the window is confirmed.
        MD
end

message = ARGV.join(" ")
message = "I want my money back for order #4471" if message.empty?
puts support.reply(message)
# => The agent loads the "refunds" skill, then follows it — e.g. asks to confirm
#    the order is within the 30-day window and offers store credit first.
