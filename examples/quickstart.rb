# frozen_string_literal: true

# The ≤10-line quickstart. One command:
#   DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb "hi, what can you do?"
#
# `serve` instead of `reply` boots the control UI (/studio) + drop-in API (/v1):
#   DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb --serve
require_relative "../lib/insika"

assistant = Insika.agent("assistant") do
  model "deepseek-chat"
  provider :deepseek
  instructions "You are Bia, a concise and friendly assistant. Answer briefly."
end

if ARGV.delete("--serve")
  assistant.serve # /studio + /v1 on http://localhost:9292
else
  puts assistant.reply(ARGV.join(" ").empty? ? "hi, what can you do?" : ARGV.join(" "))
end
