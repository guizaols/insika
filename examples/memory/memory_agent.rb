# frozen_string_literal: true

# memory — cross-session memory. With `memory true`, the agent gets a built-in
# `remember` tool to store durable facts, and those facts are injected back into
# later turns — including turns in a DIFFERENT session. Memory is per-agent.
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/memory/memory_agent.rb
#   DEEPSEEK_API_KEY=sk-... INSIKA_DB=./memory.db ruby examples/memory/memory_agent.rb  # survives restarts
require_relative "../../lib/insika"

concierge = Insika.agent("concierge") do
  model "deepseek-v4-flash"
  provider :deepseek
  memory true
  instructions <<~PROMPT
    You are a concierge. When the user shares a durable preference or fact about
    themselves, store it with the remember tool. Use what you remember to give
    personal suggestions. Keep replies short.
  PROMPT
end

# Session A — a Monday chat. The agent stores the facts.
puts "── session A ──"
puts concierge.reply("Remember that I'm vegetarian and I live in Lisbon.", session: "alice-mon")
# => "Got it — noted that you're vegetarian and based in Lisbon."

# Session B — a brand-new Friday chat. Nothing from A's transcript is here, but
# the remembered facts are: cross-session memory carries them across.
puts "── session B ──"
puts concierge.reply("Any dinner suggestions for tonight?", session: "alice-fri")
# => "Since you're in Lisbon and vegetarian, try … (a veg-friendly spot)."
