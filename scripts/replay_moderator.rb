# frozen_string_literal: true

# Replays the output moderator over the replies it already flagged in production,
# with the prompt the DEPLOYED code builds today, and says which flags still stand.
# Built to check the fix that shows the moderator the agent's instructions: an
# "invented policy" flag on a policy the pack states should clear, a real one
# should stay.
#
# Usage:
#   bundle exec ruby scripts/replay_moderator.rb <store.db> [--agent ID] [--model provider/model] [--all]
#
#   --agent   only this agent's flags
#   --model   the moderator model (default: the platform utility_model, else
#             DEEPSEEK_MODEL); credentials come from the usual *_API_KEY env vars
#   --all     also replay resolved flags (default: open moderator flags only)
#
# Read-only (SQLite mode=ro): nothing is written to the store. One model call per
# flag. Deterministic flags (injection, PII) never went through the moderator and
# are skipped.
#
# What is rebuilt, and how close it is to the original turn:
#   · the reply and the user message (which carries the caller's context: cart,
#     purchase history, coupon) are the stored ones, exact;
#   · tool results and the earlier conversation are the session's messages up to
#     that reply, exact when the session stores them;
#   · the caller state (shopping list, store, cart) is the turn task's turn_state,
#     exact while the task is kept;
#   · the system text is the agent's prompt files AS THEY ARE NOW — production does
#     not keep each turn's prompt, so a pack edited since the turn makes it approximate.

if %w[-h --help].include?(ARGV[0]) || ARGV.empty?
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit(ARGV.empty? ? 1 : 0)
end

require_relative "../lib/insika"
require "json"
require "sqlite3"
require "ruby_llm"

path = ARGV[0]
agent_filter = ARGV[ARGV.index("--agent") + 1] if ARGV.include?("--agent")
model_arg = ARGV[ARGV.index("--model") + 1] if ARGV.include?("--model")
include_resolved = ARGV.include?("--all")

db = SQLite3::Database.new("file:#{path}?mode=ro", flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
rows = ->(scope) { db.execute("SELECT key, value FROM kv WHERE scope = ?", [scope]).map { |k, v| [k, JSON.parse(v)] } }

settings = rows.("config:settings").map(&:last).first || {}
model_ref = model_arg || Insika::Coercion.presence(settings["utility_model"]) || "deepseek/#{ENV.fetch('DEEPSEEK_MODEL', 'deepseek-v4-flash')}"
provider, model = model_ref.include?("/") ? model_ref.split("/", 2) : [nil, model_ref]

RubyLLM.configure do |c|
  c.deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
  c.deepseek_api_base = ENV.fetch("DEEPSEEK_API_BASE", "https://api.deepseek.com/v1")
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  c.gemini_api_key = ENV["GEMINI_API_KEY"]
  c.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  c.request_timeout = 120
end
ask = lambda do |prompt|
  RubyLLM.chat(model: model, provider: provider, assume_model_exists: !provider.nil?)
         .with_temperature(0).ask(prompt).content.to_s
end

pack = rows.("config:agent_files").to_h do |agent, record|
  files = record.fetch("files", {}).sort.map { |name, file| "## #{name}\n#{file['content']}" }
  [agent, files.join("\n\n")]
end

text_of = lambda do |m|
  c = m.is_a?(Hash) ? m["content"] : nil
  c.is_a?(Array) ? c.filter_map { |p| p.is_a?(Hash) ? p["text"] : p.to_s }.join("\n") : c.to_s
end

# Same seam the engine uses: the validator reads instructions off a chat and the
# caller's context off the state, then builds the prompt the deployed code builds.
validator = Insika::Safety::OutputValidator.new
Msg = Struct.new(:role, :content)
Chat = Struct.new(:messages)

turn_tasks = Hash.new { |h, k| h[k] = [] }
rows.("tasks").map(&:last).sort_by { |t| t["created_at"].to_s }.each do |t|
  payload = t.dig("command", "payload") || {}
  turn_tasks[payload["session_id"]] << payload if payload["session_id"]
end

puts "moderator: #{model_ref} · store: #{path}"
results = Hash.new(0)

rows.("sessions").each do |_key, session|
  agent = session.dig("vars", "agent")
  next if agent_filter && agent != agent_filter

  messages = Array(session["messages"])
  messages.each_with_index do |m, i|
    Array(m["guardrail_flags"]).each do |flag|
      next unless flag["source"] == "moderator"
      next if flag["category"] == "moderator_unavailable"
      next unless include_resolved || Insika::SessionStore.open_flag?(flag)

      following = messages[(i + 1)..].take_while { |n| n["role"] != "user" }
      reply = following.select { |n| n["role"] == "assistant" }.map { |n| text_of.(n) }.reject(&:empty?).last.to_s
      earlier = messages[0...i].map { |n| Msg.new(n["role"].to_s, text_of.(n)) }
      tools = following.select { |n| n["role"] == "tool" }.map { |n| Msg.new(:tool, text_of.(n)) }

      state = Insika::TurnState.new(task: nil, profile: nil, turn: 1, message: "")
      state.chat = Chat.new([Msg.new(:system, pack.fetch(agent, "")), *earlier, *tools])
      state.chat_baseline = 1 + earlier.size
      state.caller_context = text_of.(m) # the stored user message: context blocks + what the customer typed
      # the turn's caller state (shopping list, store, cart) lives on the task, not in the message
      task = turn_tasks[session["id"]].reverse.find { |c| !c["message"].to_s.empty? && state.caller_context.end_with?(c["message"].to_s) }
      state.caller_state = task&.fetch("turn_state", nil)
      prompt = validator.send(:build_prompt, reply,
                              validator.send(:turn_tool_results, state), validator.send(:agent_instructions, state),
                              validator.send(:earlier_conversation, state))

      verdict = begin
        JSON.parse(ask.(prompt)[/\{.*\}/m] || "{}")
      rescue StandardError => e
        { "error" => e.message }
      end
      status = if verdict["error"] then "error"
               elsif verdict["flagged"] == true then "still flagged"
               else "cleared"
               end
      results[status] += 1

      puts "\n#{status.upcase} · #{agent} · #{session['id']} ##{i}"
      puts "  before: #{flag['category']} — #{flag['detail']}"
      puts "  now:    #{verdict['error'] || "#{verdict['category']} — #{verdict['reason']}"}"
      puts "  reply:  #{reply[0, 200].gsub("\n", ' ')}"
    end
  end
end

puts "\n#{results.empty? ? 'no moderator flags to replay' : results.map { |k, v| "#{k}: #{v}" }.join(' · ')}"
puts "note: the system text is the pack as it is now; see --help."
