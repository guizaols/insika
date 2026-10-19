#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the chat moderator with the judgment moderator on a labeled corpus.
# On-demand, not CI: needs provider keys (DeepSeek + TypeSafe) in the env.
#
# Usage:
#   TYPESAFE_API_KEY=… DEEPSEEK_API_KEY=… ruby evals/moderator/run.rb \
#     --chat deepseek/deepseek-chat --judge typesafe/jev-latest [--threshold 0.8] [--repeat 3] [--live]
#
# Without --live it only validates the corpus. Message text is never printed.
# Prints one line per case: every judge answer (category@confidence, one per
# call), what decided the judge_with_fallback verdict, and chat's verdict.

require "optparse"
require "yaml"
require "json"
require_relative "../../lib/insika"

opts = { input: File.expand_path("pt-br.yml", __dir__), threshold: 0.8, repeat: 1, live: false }
OptionParser.new do |o|
  o.on("--input FILE") { |v| opts[:input] = v }
  o.on("--chat REF") { |v| opts[:chat] = v }
  o.on("--judge REF") { |v| opts[:judge] = v }
  o.on("--threshold N", Float) { |v| opts[:threshold] = v }
  o.on("--repeat N", Integer) { |v| opts[:repeat] = v }
  o.on("--live") { opts[:live] = true }
end.parse!

cases = YAML.safe_load_file(opts[:input]).fetch("cases").map { |c| c.transform_keys(&:to_s) }
ids = cases.map { |c| c["id"] }
abort "duplicate ids" unless ids.uniq.size == ids.size
abort "bad expected" unless cases.all? { |c| %w[allow refuse escalate].include?(c["expected"]) }
unless opts[:live]
  puts "#{cases.size} cases OK. Add --live --chat REF --judge REF to run."
  exit 0
end
abort "--chat and --judge are required with --live" unless opts[:chat] && opts[:judge]

require "ruby_llm"
RubyLLM.configure do |c|
  c.deepseek_api_key = ENV["DEEPSEEK_API_KEY"]
  c.typesafe_api_key = ENV["TYPESAFE_API_KEY"]
end

settings = Insika::SettingsStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
settings.update("utility_model" => opts[:chat])
factory = Insika::Safety::Factory.new(settings_store: settings)
chat = factory.send(:moderator_for, Insika::Safety::Config.from_hash("moderator" => opts[:chat]))
judge_provider, judge_model = opts[:judge].split("/", 2)
raw_judge = factory.send(:build_judge, judge_model, judge_provider)
answers = Hash.new { |h, k| h[k] = [] }
judge = lambda do |message|
  answer = raw_judge.call(message)
  answers[message] << answer
  answer
rescue StandardError => e
  answers[message] << { "category" => "error:#{e.class}", "confidence" => 0.0 }
  raise
end
judge_only = Insika::Safety::JudgeModerator.new(judge: judge, threshold: opts[:threshold])
with_fallback = Insika::Safety::JudgeModerator.new(judge: judge, fallback: chat, threshold: opts[:threshold])

compare = Insika::Evals::ModeratorCompare.new(
  moderators: { "chat" => chat, "judge_only" => judge_only, "judge_with_fallback" => with_fallback }
)
reports = Array.new(opts[:repeat]) { compare.run(cases) }

reports.each_with_index do |report, i|
  report.each do |name, r|
    puts "run #{i + 1} #{name}: #{r['correct']}/#{r['total']} false_blocks=#{r['false_blocks']} " \
         "missed_blocks=#{r['missed_blocks']} unavailable=#{r['unavailable']} p50=#{r['p50_ms']}ms p95=#{r['p95_ms']}ms"
  end
end
puts
cases.each do |c|
  judged = answers[c["message"]].map { |a| "#{a['category']}@#{a['confidence'].round(2)}" }.join(" ")
  final = reports.map do |rep|
    v = rep["judge_with_fallback"]["verdicts"][c["id"]]
    "#{v['action']}(#{v['reason'].start_with?('judge ') ? 'judge' : 'fallback'})"
  end.join(" ")
  chat_v = reports.map { |rep| rep["chat"]["verdicts"][c["id"]]["action"] }.join(" ")
  puts "#{c['id'].ljust(22)} expected=#{c['expected'].ljust(8)} judge=[#{judged}] final=[#{final}] chat=[#{chat_v}]"
end
