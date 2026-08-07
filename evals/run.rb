#!/usr/bin/env ruby
# frozen_string_literal: true

# Eval runner CLI (RFC-0008). Replays the golden set against a RUNNING insika over
# POST /v1/responses and reports the verdict. On-demand (not CI): it needs a live
# provider key + the target agents provisioned (see evals/README.md).
#
# Usage:
#   ADMIN_TOKEN=… ruby evals/run.rb [--base-url URL] [--source store|dir]
#                                   [--agent ID] [--mode eval|perf|both] [--out FILE]
#
# Cases come from the STORE when a deployment has any (`insika evals:import` seeds it
# from `evals/golden/`), else from the corpus on disk — so an operator can add a case
# in the Studio without a checkout, and a checkout still runs without a database.
# The JUDGES come from `settings["evals"]` unless a flag overrides them: a panel of
# distinct models is configuration, not a thing to remember on the command line.
#
# Exit code: non-zero if any eval case failed (the seed of the Fase C pre-merge gate).

require "optparse"
require "time"
require "json"
require "fileutils"
# The harness itself lives in the engine now (`Insika::Evals`, RFC-0013 §3.7) — one
# evaluator, three callers: this CLI, the refinement gate, and the Studio. This file
# is the CLI: flags, wiring, exit code.
require_relative "../lib/insika"

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
  o.on("--source SRC", %w[auto store dir], "where cases come from (default auto)") { |v| opts[:source] = v }
  o.on("--agent ID", "only run goldens for this agent") { |v| opts[:agent] = v }
  o.on("--conv-map FILE", "JSON map golden.id -> conversation id (e.g. real Chat UUIDs)") { |v| opts[:conv_map] = v }
  o.on("--mode MODE", %w[eval perf both], "eval | perf | both (default eval)") { |v| opts[:mode] = v }
  o.on("--out FILE", "write the JSON report here (default evals/reports/<ts>.json)") { |v| opts[:out] = v }
  o.on("--timeout N", Integer, "per-turn read timeout seconds (default 120)") { |v| opts[:timeout] = v }
  o.on("--judge-model MODEL", "score rubrics with this model (else EVAL_JUDGE_MODEL; off if unset)") { |v| opts[:judge_model] = v }
  o.on("--judge-provider PROVIDER", "provider for the judge model (optional)") { |v| opts[:judge_provider] = v }
  o.on("--quorum N", Integer, "samples per judge; median wins (default from settings, else 1)") { |v| opts[:quorum] = v }
  o.on("--aggregate KIND", %w[median mean min], "how a judge PANEL's scores combine") { |v| opts[:aggregate] = v }
  o.on("--min-agreement F", Float, "fraction of judges that must pass (default 0.5)") { |v| opts[:min_agreement] = v }
  o.on("--no-judge", "disable the LLM-judge (rubric cases stay judge_pending)") { opts[:judge_model] = nil }
  o.on("--baseline FILE", "gate against this baseline (blocks on regressions only)") { |v| opts[:baseline] = v }
  o.on("--tolerance F", Float, "max judge-score drop before it's a regression (default 0.05)") { |v| opts[:tolerance] = v }
  o.on("--update-baseline", "write the current run as the baseline and don't gate") { opts[:update_baseline] = true }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

# Platform config (the same record the Studio edits). Absent database -> {}, and every
# read below falls back to the DEFAULTS the SettingsStore already overlays.
def eval_settings
  db = Insika::EnvSchema.read("INSIKA_DB", ENV)
  return {} if db.nil? || db.empty?

  store = Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db))
  Insika::SettingsStore.new(config_store: store).get["evals"] || {}
rescue StandardError => e
  warn "eval: could not read settings (#{e.class}) — using flags/defaults only"
  {}
end

# The judge PANEL: one entry per model. Flags win over `settings["evals"]["judges"]`,
# which is where an operator configures them (RFC-0013 §3.9). Nil when there is nobody
# to ask — rubric'd cases then read as judge_pending instead of silently passing.
# The construction moved to `Insika::Evals::JudgePanel` when the refinement gate
# became a second caller (RFC-0013 §3.7): the gate has to grade with the judges the
# operator configured, and two builders would drift. This is the CLI half — the
# provider keys and the flag precedence.
def build_judge(opts, settings)
  models = Insika::Evals::JudgePanel.resolve_models(settings, stringify_judge_opts(opts))
  return nil if models.empty?

  require "ruby_llm"
  RubyLLM.configure do |c|
    c.deepseek_api_key = ENV["DEEPSEEK_API_KEY"] if ENV["DEEPSEEK_API_KEY"]
    c.openai_api_key = ENV["OPENAI_API_KEY"] if ENV["OPENAI_API_KEY"]
    c.openai_api_base = ENV["OPENAI_API_BASE"] if ENV["OPENAI_API_BASE"]
  end
  Insika::Evals::JudgePanel.build(settings, overrides: stringify_judge_opts(opts))
end

def stringify_judge_opts(opts)
  %i[judge_model judge_provider quorum aggregate min_agreement]
    .each_with_object({}) { |k, acc| acc[k.to_s] = opts[k] unless opts[k].nil? }
end

# Cases from the STORE when the deployment has any, else the corpus on disk. `auto`
# prefers the store precisely because that is the authored, operator-editable copy;
# `--source dir` is how a checkout runs with no database at all.
def load_goldens(opts)
  db = Insika::EnvSchema.read("INSIKA_DB", ENV)
  if opts[:source] != "dir" && db && !db.empty?
    store = Insika::GoldenStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::SQLite.new(path: db)))
    cases = store.all
    invalid = store.invalid
    warn "eval: #{invalid.size} stored case(s) no longer validate and were skipped: #{invalid.join(', ')}" if invalid.any?
    return [cases, "store"] if cases.any?

    abort "eval: --source store, but the store holds no case (run `insika evals:import`)" if opts[:source] == "store"
  end
  [Insika::Evals::GoldenLoader.load_dir(opts[:golden_dir]), opts[:golden_dir]]
end

settings = eval_settings
goldens, source = load_goldens(opts)
goldens = goldens.select { |g| g.agent == opts[:agent] } if opts[:agent]
abort "eval: no goldens found in #{source}" if goldens.empty?

conv_map = opts[:conv_map] ? JSON.parse(File.read(opts[:conv_map])) : {}
transport = Insika::Evals::HttpTransport.new(base_url: opts[:base_url], token: opts[:token], timeout: opts[:timeout])
judge, judge_models = build_judge(opts, settings)
judge_note = judge ? "judges=#{judge_models.join('+')}" : "judge=off"
puts "eval -> #{opts[:base_url]} | #{goldens.size} case(s) from #{source} | mode=#{opts[:mode]} | #{judge_note}"

# What the deployment HAS, per agent — what a case's `requires` resolves against
# (RFC-0014 §3.2). Same base_url and token as the replay; an unreachable or older
# deployment answers nil and the case RUNS, warned about below.
capabilities = Insika::Evals::HttpCapabilities.new(base_url: opts[:base_url], token: opts[:token])
runcases = Insika::Evals::Runner.new(transport: transport, judge: judge, conv_map: conv_map,
                                     capabilities: capabilities).run(goldens)
results = runcases.map(&:result)

# A case that declared requirements, was not skipped, and was not resolved either:
# it ran unchecked. Say so once, rather than letting the run look fully gated.
unresolved = goldens.select(&:requirements?).map(&:agent).uniq.reject { |a| capabilities.for(a) }
unless unresolved.empty?
  warn "eval: could not read /v1/agents for #{unresolved.join(', ')} — cases with `requires` ran unchecked"
end
at = Time.now.utc.iso8601

# --- eval verdict ---------------------------------------------------------------
if %w[eval both].include?(opts[:mode])
  puts
  puts Insika::Evals::Report.to_markdown(results, at: at)

  out = opts[:out] || File.join(__dir__, "reports", "#{at.tr(':', '-')}.json")
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, Insika::Evals::Report.to_json(results, at: at))
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
    Insika::Evals::Baseline.write(target, results, at: at)
    puts "baseline updated: #{target} (#{results.size} cases)"
  elsif baseline_path
    regressions = Insika::Evals::Baseline.compare(results, Insika::Evals::Baseline.load(baseline_path), tolerance: (opts[:tolerance] || settings["tolerance"] || 0.05))
    if regressions.any?
      warn "eval: #{regressions.size} regression(s) vs baseline (#{baseline_path}):"
      regressions.each { |r| warn "  - #{r.id}: #{r.kind} — #{r.detail}" }
      exit 1
    end
    puts "no regressions vs baseline (#{baseline_path})"
  else
    failed = results.reject(&:skipped?).count { |r| !r.pass? }
    if failed.positive?
      warn "eval: #{failed} case(s) failed (no baseline — run with --update-baseline to accept)"
      exit 1
    end
  end
end
