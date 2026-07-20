#!/usr/bin/env ruby
# frozen_string_literal: true

# Eval runner CLI (RFC-0008). Replays the golden set against a RUNNING harness over
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
require "fileutils"
require_relative "lib/evals/golden"
require_relative "lib/evals/assertions"
require_relative "lib/evals/report"
require_relative "lib/evals/transport"
require_relative "lib/evals/runner"

opts = {
  base_url: ENV["HARNESS_URL"] || "http://localhost:9292",
  token: ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo",
  golden_dir: File.expand_path("golden", __dir__),
  mode: "eval",
  agent: nil,
  out: nil,
  timeout: 120
}

OptionParser.new do |o|
  o.banner = "Usage: ruby evals/run.rb [options]"
  o.on("--base-url URL", "harness base URL (default #{opts[:base_url]})") { |v| opts[:base_url] = v }
  o.on("--golden-dir DIR", "golden set dir (default evals/golden)") { |v| opts[:golden_dir] = v }
  o.on("--agent ID", "only run goldens for this agent") { |v| opts[:agent] = v }
  o.on("--mode MODE", %w[eval perf both], "eval | perf | both (default eval)") { |v| opts[:mode] = v }
  o.on("--out FILE", "write the JSON report here (default evals/reports/<ts>.json)") { |v| opts[:out] = v }
  o.on("--timeout N", Integer, "per-turn read timeout seconds (default 120)") { |v| opts[:timeout] = v }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

goldens = Evals::GoldenLoader.load_dir(opts[:golden_dir])
goldens.select! { |g| g.agent == opts[:agent] } if opts[:agent]
abort "eval: no goldens found in #{opts[:golden_dir]}" if goldens.empty?

transport = Evals::HttpTransport.new(base_url: opts[:base_url], token: opts[:token], timeout: opts[:timeout])
puts "eval -> #{opts[:base_url]} | #{goldens.size} case(s) | mode=#{opts[:mode]}"

runcases = Evals::Runner.new(transport: transport).run(goldens)
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

# --- gating: non-zero exit if any eval case failed ------------------------------
failed = results.count { |r| !r.pass? }
if %w[eval both].include?(opts[:mode]) && failed.positive?
  warn "eval: #{failed} case(s) failed"
  exit 1
end
