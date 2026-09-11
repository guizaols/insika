#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-grades recorded cells with the graders as they are NOW. A run stores what the
# case saw — every reply, every call and how it ended, the store afterwards — so a
# grader written after the run can still be applied to it without buying the cells
# again. That is how the phantom-action check got a number out of cut 3: the
# transcripts already held six turn-ones that said "adicionado" and called nothing.
#
#   ruby evals/bench/regrade.rb [RUNS_DIR ...]     # default: every runs* beside it
#
# Rewrites `checks` and `pass` in each transcript and in its per-cell report, then
# lists the cells whose verdict flipped. Wall clock and tokens are left alone: they
# were measured, and no grader can re-measure them.
require "json"
require_relative "../../lib/insika"

bench = __dir__
goldens = Insika::Evals::GoldenLoader.load_dir(File.join(bench, "tasks")).to_h { |g| [g.id, g] }
dirs = ARGV.empty? ? Dir[File.join(bench, "runs*")].sort : ARGV
flips = []
cells = 0

dirs.each do |runs|
  Dir[File.join(runs, "*", "*", "transcripts", "r*", "*.json")].sort.each do |path|
    t = JSON.parse(File.read(path))
    golden = goldens[t["id"]] or next
    next if t["skipped"]

    round = path[%r{/transcripts/(r\d+)/}, 1]
    report_path = File.join(path.split("/transcripts/").first, "#{t['id']}-#{round}.json")
    report = File.exist?(report_path) ? JSON.parse(File.read(report_path)) : nil
    cell = report&.dig("cases")&.find { |c| c["id"] == t["id"] }

    turns = t["turns"].map do |turn|
      Insika::Evals::TurnResult.new(output_text: turn["reply"], tool_calls: turn["tool_calls"], ui: [], error: turn["error"])
    end
    # A harness that could not report its calls had its tool graders skipped, and the
    # per-cell report is where that was written down.
    tools_reported = !Array(cell&.dig("checks")).any? { |c| c["skipped"] }
    verdict = Insika::Evals::Assertions.evaluate(golden, turns.last, turns: turns, store: t["store"],
                                                 tools_reported: tools_reported)

    was = t["pass"]
    t["pass"] = verdict.pass?
    t["checks"] = verdict.checks.map { |c| { "name" => c.name, "pass" => c.pass, "detail" => c.detail } }
    File.write(path, JSON.pretty_generate(t))
    if cell
      cell["pass"] = verdict.pass?
      cell["checks"] = verdict.checks.map do |c|
        { "name" => c.name, "pass" => c.pass, "detail" => c.detail, "skipped" => (true if c.skipped?) }.compact
      end
      ran = report["cases"].reject { |c| c["skipped"] }
      report["passed"] = ran.count { |c| c["pass"] }
      report["failed"] = ran.size - report["passed"]
      File.write(report_path, JSON.pretty_generate(report))
    end
    cells += 1
    flips << [path.sub("#{bench}/", ""), was, verdict.pass?] if was != verdict.pass?
  end
end

puts "regraded #{cells} cell(s) in #{dirs.size} run dir(s); #{flips.size} changed verdict"
flips.each { |p, was, now| puts "  #{was ? 'pass' : 'fail'} -> #{now ? 'pass' : 'fail'}  #{p}" }
