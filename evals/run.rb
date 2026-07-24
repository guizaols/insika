#!/usr/bin/env ruby
# frozen_string_literal: true

# Eval runner CLI (RFC-0008). Replays the golden set against a RUNNING insika over
# POST /v1/responses and reports the verdict. On-demand (not CI): it needs a live
# provider key + the target agents provisioned (see evals/README.md).
#
# Usage:
#   ADMIN_TOKEN=… ruby evals/run.rb [--base-url URL] [--golden-dir DIR]
#                                   [--agent ID] [--mode eval|perf|both] [--out FILE]
#
# Exit code: non-zero if any eval case failed (the seed of the Fase C pre-merge gate).

require "optparse"
require "time"
require "json"
require "fileutils"
require_relative "lib/evals/golden"
require_relative "lib/evals/assertions"
require_relative "lib/evals/report"
require_relative "lib/evals/transport"
require_relative "lib/evals/runner"
require_relative "lib/evals/judge"
require_relative "lib/evals/baseline"

opts = {
  base_url: ENV["INSIKA_URL"] || ENV["HARNESS_URL"] || "http://localhost:9292",
  token: ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo",
  golden_dir: File.expand_path("golden", __dir__),
  mode: "eval",
  agent: nil,
  out: nil,
  timeout: 120,
  # Optional golden.id -> conversation-id map (JSON). Needed when the target
  # backend resolves state from a pre-existing conversation record (e.g. consumer-app
  # requires a real Chat UUID as X-Chat-Id). Absent -> conv defaults to "eval-<id>".
  conv_map: nil,
  # Judge (Fase B): the model that scores rubrics. Off unless a model is given
  # (via flag or EVAL_JUDGE_MODEL) — without it, rubric'd cases stay judge_pending.
  judge_model: ENV["EVAL_JUDGE_MODEL"],
  judge_provider: ENV["EVAL_JUDGE_PROVIDER"],
  quorum: 1,
  # Fase C gating.
  baseline: nil,
  tolerance: 0.05,
  update_baseline: false
}

OptionParser.new do |o|
  o.banner = "Usage: ruby evals/run.rb [options]"
  o.on("--base-url URL", "insika base URL (default #{opts[:base_url]})") { |v| opts[:base_url] = v }
  o.on("--golden-dir DIR", "golden set dir (default evals/golden)") { |v| opts[:golden_dir] = v }
  o.on("--agent ID", "only run goldens for this agent") { |v| opts[:agent] = v }
  o.on("--conv-map FILE", "JSON map golden.id -> conversation id (e.g. real Chat UUIDs)") { |v| opts[:conv_map] = v }
  o.on("--mode MODE", %w[eval perf both], "eval | perf | both (default eval)") { |v| opts[:mode] = v }
  o.on("--out FILE", "write the JSON report here (default evals/reports/<ts>.json)") { |v| opts[:out] = v }
  o.on("--timeout N", Integer, "per-turn read timeout seconds (default 120)") { |v| opts[:timeout] = v }
  o.on("--judge-model MODEL", "score rubrics with this model (else EVAL_JUDGE_MODEL; off if unset)") { |v| opts[:judge_model] = v }
  o.on("--judge-provider PROVIDER", "provider for the judge model (optional)") { |v| opts[:judge_provider] = v }
  o.on("--quorum N", Integer, "judge samples per case; median wins (default 1)") { |v| opts[:quorum] = v }
  o.on("--no-judge", "disable the LLM-judge (rubric cases stay judge_pending)") { opts[:judge_model] = nil }
  o.on("--baseline FILE", "gate against this baseline (blocks on regressions only)") { |v| opts[:baseline] = v }
  o.on("--tolerance F", Float, "max judge-score drop before it's a regression (default 0.05)") { |v| opts[:tolerance] = v }
  o.on("--update-baseline", "write the current run as the baseline and don't gate") { opts[:update_baseline] = true }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

# Builds the LLM-judge if a model is configured. The `ask` uses RubyLLM at
# temperature 0 (deterministic-ish); credentials come from the standard env. Nil
# when no judge model is set — rubric'd cases then read as judge_pending.
def build_judge(opts)
  return nil unless opts[:judge_model]

  require "ruby_llm"
  RubyLLM.configure do |c|
    c.deepseek_api_key = ENV["DEEPSEEK_API_KEY"] if ENV["DEEPSEEK_API_KEY"]
    c.openai_api_key = ENV["OPENAI_API_KEY"] if ENV["OPENAI_API_KEY"]
    c.openai_api_base = ENV["OPENAI_API_BASE"] if ENV["OPENAI_API_BASE"]
  end
  ask = lambda do |prompt|
    RubyLLM.chat(model: opts[:judge_model], provider: opts[:judge_provider], assume_model_exists: true)
           .with_temperature(0).ask(prompt).content
  end
  Evals::Judge.new(ask: ask, quorum: opts[:quorum])
end

goldens = Evals::GoldenLoader.load_dir(opts[:golden_dir])
goldens.select! { |g| g.agent == opts[:agent] } if opts[:agent]
abort "eval: no goldens found in #{opts[:golden_dir]}" if goldens.empty?

conv_map = opts[:conv_map] ? JSON.parse(File.read(opts[:conv_map])) : {}
transport = Evals::HttpTransport.new(base_url: opts[:base_url], token: opts[:token], timeout: opts[:timeout])
judge = build_judge(opts)
judge_note = judge ? "judge=#{opts[:judge_model]} (q#{opts[:quorum]})" : "judge=off"
puts "eval -> #{opts[:base_url]} | #{goldens.size} case(s) | mode=#{opts[:mode]} | #{judge_note}"

runcases = Evals::Runner.new(transport: transport, judge: judge, conv_map: conv_map).run(goldens)
results = runcases.map(&:result)
at = Time.now.utc.iso8601

# --- eval verdict ---------------------------------------------------------------
if %w[eval both].include?(opts[:mode])
  puts
  puts Evals::Report.to_markdown(results, at: at)

  out = opts[:out] || File.join(__dir__, "reports", "#{at.tr(':', '-')}.json")
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, Evals::Report.to_json(results, at: at))
  puts "report: #{out}"
end

# --- perf summary (real-traffic latency — #6b) ----------------------------------
if %w[perf both].include?(opts[:mode])
  def pct(sorted, p)
    return 0.0 if sorted.empty?

    r = (p / 100.0) * (sorted.length - 1)
    lo = sorted[r.floor]
    hi = sorted[r.ceil]
    (lo + (hi - lo) * (r - r.floor)).round(1)
  end

  timings = runcases.flat_map(&:timings)
  ttfbs = timings.map { |t| t[:ttfb] }.compact.sort
  totals = timings.map { |t| t[:total] }.compact.sort
  puts
  puts "perf (#{timings.size} turns over real corpus):"
  puts "  TTFB  p50/p95: #{pct(ttfbs, 50)} / #{pct(ttfbs, 95)} ms"
  puts "  total p50/p95: #{pct(totals, 50)} / #{pct(totals, 95)} ms"
end

# --- gating (Fase C) ------------------------------------------------------------
# With a baseline: block only on REGRESSIONS (a passing case that now fails, or a
# judge score that dropped past --tolerance) — known failures don't wedge the gate.
# --update-baseline accepts the current run as the new baseline. With no baseline at
# all, fall back to "fail if any case failed". Perf-only runs never gate.
if %w[eval both].include?(opts[:mode])
  default_baseline = File.join(__dir__, "baseline.json")
  baseline_path = opts[:baseline] || (File.exist?(default_baseline) ? default_baseline : nil)

  if opts[:update_baseline]
    target = opts[:baseline] || default_baseline
    Evals::Baseline.write(target, results, at: at)
    puts "baseline updated: #{target} (#{results.size} cases)"
  elsif baseline_path
    regressions = Evals::Baseline.compare(results, Evals::Baseline.load(baseline_path), tolerance: opts[:tolerance])
    if regressions.any?
      warn "eval: #{regressions.size} regression(s) vs baseline (#{baseline_path}):"
      regressions.each { |r| warn "  - #{r.id}: #{r.kind} — #{r.detail}" }
      exit 1
    end
    puts "no regressions vs baseline (#{baseline_path})"
  else
    failed = results.count { |r| !r.pass? }
    if failed.positive?
      warn "eval: #{failed} case(s) failed (no baseline — run with --update-baseline to accept)"
      exit 1
    end
  end
end
