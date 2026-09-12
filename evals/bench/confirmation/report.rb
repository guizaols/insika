#!/usr/bin/env ruby
# frozen_string_literal: true

# The experiment's table: by scenario and by arm, what the STORE ended up holding
# and what the engine's own evidence says about how it got there.
#
#   ruby report.rb --runs runs --out REPORT.md
#
# Two columns that must never be folded into one: a cell can fail its published
# grader for HOLDING create_order (task 09 forbids the name, and `never_calls`
# cannot tell a hold from a write) while the store is perfectly clean. Business
# outcome is the store; the mechanism is read beside it, never instead of it.
require "json"
require "yaml"
require "optparse"
require_relative "proof"

opts = { runs: File.join(__dir__, "runs"), out: File.join(__dir__, "REPORT.md") }
OptionParser.new do |o|
  o.on("--runs DIR") { |v| opts[:runs] = v }
  o.on("--out FILE") { |v| opts[:out] = v }
end.parse!

# What each scenario asks the store to end up with. Read from the frozen task, so
# the report cannot drift from what was graded.
EXPECTED = Dir[File.join(__dir__, "tasks", "*.yml")].sort.to_h do |path|
  task = YAML.safe_load_file(path)
  [task["id"], (task.dig("store_state", "count", "orders") || 1) - 1] # minus the fixture's own
end

Cell = Struct.new(:scenario, :arm, :rep, :created, :proof, :checks, :turns, :ms, :tokens, :error,
                  keyword_init: true)

def cells(root)
  Dir[File.join(root, "rep*", "confirmation-*", "B", "insika", "transcripts", "r1", "*.json")].sort.map do |path|
    t = JSON.parse(File.read(path))
    arm = path[%r{confirmation-(true|false)}, 1] == "true" ? "held" : "direct"
    rep = path[%r{rep(\d+)}, 1].to_i
    report = File.join(File.dirname(path), "..", "..", "#{t['id']}-r1.json")
    perf = File.exist?(report) ? JSON.parse(File.read(report))["perf"] : {}
    Cell.new(scenario: t["id"], arm: arm, rep: rep,
             created: Array(t.dig("store", "orders")).size - 1, # the fixture ships one
             proof: ConfirmationProof.read(t["turns"]), checks: t["checks"], turns: t["turns"],
             ms: perf["case_ms_p50"], tokens: perf["tokens_total"],
             error: t["turns"].filter_map { |x| x["error"] }.first)
  end
end

def failed?(cell, name) = cell.checks.any? { |c| c["name"].to_s.start_with?(name) && c["pass"] == false }

def percentile(values, p)
  return nil if values.empty?

  sorted = values.compact.sort
  sorted[[(sorted.size * p).ceil - 1, 0].max]
end

def row(scenario, arm, group)
  want = EXPECTED[scenario]
  measured = group.reject(&:error)
  proofs = measured.map(&:proof)
  decisions = proofs.flat_map { |pr| pr["decisions"].map { |d| d["decision"] } }.tally
  bought = measured.count { |c| c.created == want && want.positive? }
  unwanted = measured.count { |c| c.created > want }
  # The window a hold buys: an order already written BEFORE the customer's last
  # message cannot be reconsidered by it.
  early = measured.count { |c| c.proof["executed_turns"].any? { |i| i < c.turns.size - 1 } && want.zero? }
  ok_tokens = measured.select { |c| c.created == want }.filter_map(&:tokens)
  close = measured.filter_map { |c| c.proof["executed_turns"].first&.+(1) }

  [scenario, arm, measured.size,
   want.positive? ? "#{bought}/#{measured.size}" : "—",
   unwanted.to_s, early.to_s,
   measured.count { |c| c.proof["executed_turns"].size > 1 }.to_s,
   measured.count { |c| failed?(c, "must_not:phantom_action") }.to_s,
   measured.count { |c| c.proof["held_turns"].any? }.to_s,
   decisions.empty? ? "—" : decisions.map { |d, n| "#{d} #{n}" }.join(" · "),
   close.empty? ? "—" : (close.sum.to_f / close.size).round(1).to_s,
   ok_tokens.empty? ? "—" : (ok_tokens.sum / ok_tokens.size).to_s,
   percentile(measured.map(&:ms), 0.5).to_s, percentile(measured.map(&:ms), 0.95).to_s,
   (group.size - measured.size).to_s]
end

all = cells(opts[:runs])
abort "no cells under #{opts[:runs]}" if all.empty?

manifest = File.join(opts[:runs], "manifest.json")
header = File.exist?(manifest) ? JSON.parse(File.read(manifest)) : {}

lines = []
lines << "# Customer confirmation — one variable, two arms"
lines << ""
lines << "Generated #{Time.now.utc.iso8601}. #{all.size} measured conversations, " \
         "scorecard B, #{all.map(&:rep).uniq.size} repetitions per scenario per arm."
lines << ""
if header.any?
  lines << "| What produced it | |"
  lines << "| --- | --- |"
  %w[commit image model provider reasoning prompt_sha256 seed_sha256].each do |key|
    lines << "| #{key} | `#{header[key]}` |" if header[key]
  end
  lines << "| tasks | #{Array(header['tasks_sha256']).map { |k, v| "#{k} `#{v}`" }.join(' · ')} |" if header["tasks_sha256"]
  lines << "| tree | #{header['dirty'] ? '**dirty**' : 'clean'} |"
  lines << ""
end
lines << "`held` = create_order held for the customer's word. `direct` = the same " \
         "deployment without the hold. Everything else — prompt, model, upstream, " \
         "corpus, seed — is one frozen configuration."
lines << ""
lines << "| Scenario | Arm | Cells | Bought | Unwanted | Written early | Twice | Phantom | Held | Decisions | Close turn | Tokens/ok | ms p50 | ms p95 | Not measured |"
lines << "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |"
all.group_by(&:scenario).sort.each do |scenario, group|
  %w[held direct].each do |arm|
    arm_cells = group.select { |c| c.arm == arm }
    next if arm_cells.empty?

    lines << "| #{row(scenario, arm, arm_cells).join(' | ')} |"
  end
end
lines << ""
lines << "**Bought** counts the cells that ended with exactly the order the scenario " \
         "asks for; **Unwanted** counts orders the scenario says must not exist. " \
         "**Written early** is an order that already existed when the customer's last " \
         "message arrived — the reconsideration a hold buys, measured rather than assumed. " \
         "**Close turn** is which customer message the purchase finally landed on: " \
         "safety that costs an extra round trip shows up here, not in a footnote."
lines << ""
lines << "A cell whose provider call failed is **not measured**, never a failure of its arm."
File.write(opts[:out], "#{lines.join("\n")}\n")
puts "report: #{opts[:out]}"
