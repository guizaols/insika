#!/usr/bin/env ruby
# frozen_string_literal: true

# The per-run JSON reports -> one REPORT.md. Two scorecards, side by side, because
# a single table with us on top would be read as marketing and would be right to be:
#
#   A — parity: same MCP tools, same model, same system prompt for everyone.
#   B — out of the box: each harness as it ships, ours included.
#
# The gap between them is the engine's value, and reporting both is the only
# version anyone will believe.
#
#   ruby evals/bench/scorecard.rb --runs evals/bench/runs --out evals/bench/REPORT.md

require "json"
require "optparse"
require "time"

opts = { runs: File.join(__dir__, "runs"), out: File.join(__dir__, "REPORT.md") }
OptionParser.new do |o|
  o.on("--runs DIR", "where run.sh wrote the per-task reports") { |v| opts[:runs] = v }
  o.on("--out FILE", "the report to write") { |v| opts[:out] = v }
  o.on("--price-per-mtok F", Float, "blended USD per million tokens, for cost per success") { |v| opts[:price] = v }
  o.on("--price-note TEXT", "the model and the date its price was read") { |v| opts[:price_note] = v }
end.parse!

# What a failing check MEANS, in the language the bench exists to speak. The order
# matters: a case that both invented a price and duplicated the order is counted
# under the worse one, and a store left wrong is worse than a reply that reads badly.
FAILURE_CLASSES = [
  # A turn that never produced an answer is not a commerce failure, and a table that
  # files it under one is describing a harness nobody measured.
  ["no answer from the harness", ->(name) { name == "turn" }],
  ["duplicate side effect", ->(name) { name.start_with?("store_state:count:") }],
  ["store left wrong",      ->(name) { name.start_with?("store_state") }],
  ["gate did not hold",     ->(name) { name.start_with?("blocked_gates:") }],
  ["invention",             ->(name) { name.start_with?("reply_omits:", "must_not:") }],
  ["wrong tool behaviour",  ->(name) { name.start_with?("tool:", "never_calls:", "calls_one_of", "first_tool:", "max_tool_calls:") }],
  # The store's own one-question rule. Its own class because it is the rule
  # production broke, not a generic bad reply.
  ["more than one question", ->(name) { name.start_with?("policy:ask_once") }],
  ["reply missed the point", ->(name) { name.start_with?("reply_includes:") }]
].freeze

def classify(check_name)
  FAILURE_CLASSES.each { |label, match| return label if match.call(check_name) }
  "other"
end

# -> { scorecard => { harness => [case hashes] } }
def load_runs(dir)
  Dir.glob(File.join(dir, "*", "*", "*.json")).reject { |f| f.end_with?(".store.json") }.sort
     .each_with_object({}) do |file, acc|
    scorecard, harness = file.split(File::SEPARATOR)[-3, 2]
    report = JSON.parse(File.read(file))
    (acc[scorecard] ||= Hash.new { |h, k| h[k] = [] })[harness].concat(Array(report["cases"]))
  end
end

def percentile(values, p)
  return nil if values.empty?

  sorted = values.sort
  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]
  hi = sorted[r.ceil]
  (lo + ((hi - lo) * (r - r.floor))).round
end

def seconds(ms) = ms.nil? ? "—" : "#{(ms / 1000.0).round(1)}s"

def row(harness, cases, price)
  ran = cases.reject { |c| c["skipped"] }
  passed = ran.count { |c| c["pass"] }
  classes = ran.reject { |c| c["pass"] }
               .flat_map { |c| Array(c["checks"]).reject { |k| k["pass"] }.map { |k| classify(k["name"]) } }
               .tally.sort_by { |_, n| -n }.map { |label, n| "#{n} #{label}" }
  skipped_graders = ran.sum { |c| Array(c["checks"]).count { |k| k["skipped"] } }

  # Wall clock as the runner measured it, around the turn. Cost is only ever shown
  # against tokens somebody actually reported: most rival harnesses report none, and
  # an invented zero would put them at the top of the column they should be absent
  # from.
  times = ran.filter_map { |c| c.dig("perf", "ms") }
  won = ran.select { |c| c["pass"] }
  tokens = won.filter_map { |c| c.dig("perf", "tokens") }
  per_success = (tokens.sum.to_f / tokens.size).round unless tokens.empty?

  { harness: harness, ran: ran.size, passed: passed,
    p50: seconds(percentile(times, 50)), p95: seconds(percentile(times, 95)),
    tokens: per_success ? per_success.to_s : "—",
    cost: (price && per_success ? format("$%.4f", per_success / 1_000_000.0 * price) : "—"),
    rate: ran.empty? ? "—" : "#{(100.0 * passed / ran.size).round}%",
    failures: classes.empty? ? "—" : classes.join(" · "),
    # Never hidden: a harness measured on fewer graders than the others has to
    # carry that on its own row, or its rate reads as comparable when it is not.
    skipped: skipped_graders.zero? ? "—" : "#{skipped_graders} grader(s) not observable" }
end

TITLES = { "A" => "Scorecard A — parity (same tools, same model, same prompt)",
           "B" => "Scorecard B — out of the box (each harness as it ships)" }.freeze

runs = load_runs(opts[:runs])
abort "scorecard: no run found under #{opts[:runs]}" if runs.empty?

lines = ["# Cross-harness commerce bench", "", "Generated #{Time.now.utc.iso8601}.", ""]
runs.keys.sort.each do |scorecard|
  lines << "## #{TITLES.fetch(scorecard, "Scorecard #{scorecard}")}" << ""
  lines << "| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |"
  lines << "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  runs[scorecard].keys.sort.each do |harness|
    r = row(harness, runs[scorecard][harness], opts[:price])
    lines << "| #{r[:harness]} | #{r[:ran]} | #{r[:passed]} | #{r[:rate]} | #{r[:p50]} | #{r[:p95]} | " \
             "#{r[:tokens]} | #{r[:cost]} | #{r[:failures]} | #{r[:skipped]} |"
  end
  lines << ""
end

if runs["A"] && runs["B"]
  lines << "## The gap" << ""
  lines << "A measures the harness; B measures the product. The distance between a" \
           " harness's two rows is what its own layer adds — for us, that is the claim." \
           " If they come out the same, the engine's commerce layer does not pay for" \
           " itself yet, and that is the finding." << ""
  # Δ in points, not cells: a scorecard interrupted mid-run has fewer cells than the
  # other, and a cell-count difference would read as a collapse that never happened.
  lines << "| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |"
  lines << "| --- | --- | --- | --- | --- | --- |"
  (runs["A"].keys | runs["B"].keys).sort.each do |harness|
    # `key?`, not `[]`: the per-scorecard hash auto-creates an empty bucket, and a
    # harness that ran in only one scorecard would then get a silent 0-cell row.
    next unless runs["A"].key?(harness) && runs["B"].key?(harness)

    a = row(harness, runs["A"][harness], opts[:price])
    b = row(harness, runs["B"][harness], opts[:price])

    delta = a[:ran].zero? || b[:ran].zero? ? nil : ((100.0 * b[:passed] / b[:ran]) - (100.0 * a[:passed] / a[:ran])).round
    shown = delta.nil? ? "—" : "#{delta.positive? ? "+" : ""}#{delta}"
    lines << "| #{harness} | #{a[:passed]}/#{a[:ran]} (#{a[:rate]}) | #{b[:passed]}/#{b[:ran]} (#{b[:rate]}) | " \
             "#{shown} | #{a[:tokens]} | #{b[:tokens]} |"
  end
  lines << ""
end
lines << "## How to read the numbers" << ""
lines << "Time is wall clock measured by the runner around each turn, summed over the" \
         " task — never self-reported. It includes the adapter's own process spawn," \
         " which every entrant pays, ours included; p50 is the honest column and p95" \
         " is where a harness that retries silently shows up."
lines << ""
lines << "Cost per success is blank for a harness that reports no token usage, and" \
         " blank is the truth: an assumed zero would put the harness that measures" \
         " nothing at the top of the column."
lines << "#{"Price: #{opts[:price]} USD per million tokens — #{opts[:price_note]}." if opts[:price]}"
lines << ""
lines << "Every cell traces to a run log under `#{File.basename(opts[:runs])}/`." << ""

File.write(opts[:out], lines.join("\n"))
puts "wrote #{opts[:out]}"
