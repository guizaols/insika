# frozen_string_literal: true

# hello-agent — the smallest possible agent: one prompt, one turn.
#
#   DEEPSEEK_API_KEY=sk-... ruby examples/hello-agent/hello.rb "your message"
#   DEEPSEEK_API_KEY=sk-... ruby examples/hello-agent/hello.rb --serve
require_relative "../../lib/insika"

assistant = Insika.agent("assistant") do
  model "deepseek-v4-flash"
  provider :deepseek
  instructions "You are a concise, friendly assistant. Answer briefly."
end

if ARGV.delete("--serve")
  # Same agent, now a server: control UI (/studio) + drop-in /v1/responses on :9292.
  assistant.serve
else
  message = ARGV.join(" ")
  message = "hi, what can you do?" if message.empty?
  puts assistant.reply(message)
  # => "Hi! I can answer questions, explain things, and help you think through
  #     problems — briefly. What do you need?"
end
