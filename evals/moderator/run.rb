#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares the chat moderator with the judgment moderator on a labeled corpus.
# On-demand, not CI: needs provider keys (DeepSeek + TypeSafe) in the env.
#
# Usage:
#   TYPESAFE_API_KEY=… DEEPSEEK_API_KEY=… ruby evals/moderator/run.rb \
#     --chat deepseek/deepseek-chat --judge typesafe/jev-latest [--threshold 0.8] [--live]
#
# Without --live it only validates the corpus. Message text is never printed.

require "optparse"
require "yaml"
require "json"
require_relative "../../lib/insika"

opts = { input: File.expand_path("pt-br.yml", __dir__), threshold: 0.8, live: false }
OptionParser.new do |o|
  o.on("--input FILE") { |v| opts[:input] = v }
  o.on("--chat REF") { |v| opts[:chat] = v }
  o.on("--judge REF") { |v| opts[:judge] = v }
  o.on("--threshold N", Float) { |v| opts[:threshold] = v }
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
judge = factory.send(:build_judge, judge_model, judge_provider)
judge_only = Insika::Safety::JudgeModerator.new(judge: judge, threshold: opts[:threshold])
with_fallback = Insika::Safety::JudgeModerator.new(judge: judge, fallback: chat, threshold: opts[:threshold])

report = Insika::Evals::ModeratorCompare.new(
  moderators: { "chat" => chat, "judge_only" => judge_only, "judge_with_fallback" => with_fallback }
).run(cases)
puts JSON.pretty_generate(report)
