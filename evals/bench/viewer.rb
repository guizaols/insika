#!/usr/bin/env ruby
# frozen_string_literal: true

# The cut as a page you can read. `scorecard.rb` answers "who scored what";
# this answers "what did it actually say", which is the question every finding in
# this bench so far has turned on — and which used to mean writing a Ruby one-liner
# against 692 JSON files.
#
#   evals/bench/viewer.rb                        # the live runs/ roots
#   evals/bench/viewer.rb --runs cuts/2026-09-09 # a published cut
#   evals/bench/viewer.rb --out /tmp/bench.html
#
# The output is one self-contained HTML file: the data is inlined, so it opens from
# disk, travels in an attachment, and needs no server.

require "json"
require "optparse"

BENCH_DIR = File.expand_path(__dir__)

options = { runs: BENCH_DIR, out: File.join(BENCH_DIR, "bench.html") }
OptionParser.new do |o|
  o.banner = "usage: viewer.rb [--runs DIR] [--out FILE]"
  o.on("--runs DIR", "directory holding the runs* roots (default: the bench dir)") { |v| options[:runs] = File.expand_path(v) }
  o.on("--out FILE", "where to write the page") { |v| options[:out] = File.expand_path(v) }
end.parse!

# Every root the cut can produce. A root that is not there is simply not a tab.
ROOTS = {
  "guarded" => "runs",
  "unguarded" => "runs-unguarded",
  "reasoning-off" => "runs-reasoning-off",
  "probe-medium" => "runs-probe-medium",
  "probe-off" => "runs-probe-off",
  "probe-09" => "runs-probe-09"
}.freeze

cells = []
ROOTS.each do |label, dir|
  root = File.join(options[:runs], dir)
  Dir.glob(File.join(root, "*", "*", "*-r*.json")).sort.each do |path|
    card, harness, base = path.sub("#{root}/", "").split("/")
    id = base.sub(/-r\d+\.json\z/, "")
    round = base[/-r(\d+)\.json\z/, 1].to_i

    report = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      warn "viewer: unreadable report, skipped: #{path}"
      next
    end
    result = (report["cases"] || [report]).first or next

    # The reports carry the verdict; the transcripts carry what was said. A cell
    # skipped as already-measured keeps the transcript from the run that produced it,
    # so the two are always the same run.
    transcript = File.join(root, card, harness, "transcripts", "r#{round}", "#{id}.json")
    turns = File.exist?(transcript) ? (JSON.parse(File.read(transcript))["turns"] || []) : []

    cells << {
      cut: label, card: card, harness: harness, task: id, round: round,
      pass: !!result["pass"],
      ms: result.dig("perf", "ms"),
      tok: result.dig("perf", "tokens"),
      nchecks: (result["checks"] || []).size,
      fails: (result["checks"] || []).reject { |c| c["pass"] }
                                     .map { |c| { n: c["name"], d: c["detail"].to_s[0, 260] } },
      turns: turns.map { |t|
        { u: t["user"], r: t["reply"], e: t["error"], ms: t["ms"],
          t: (t["tool_calls"] || []).map { |c| c["status"] == "ok" ? c["name"] : "#{c["name"]}:#{c["status"]}" } }
          .reject { |_, v| v.nil? || v == [] }
      }
    }
  end
end

abort "viewer: no cells under #{options[:runs]}" if cells.empty?

template = File.read(File.join(BENCH_DIR, "viewer", "template.html"))
# A literal `</script>` inside the JSON would close the tag that carries it.
payload = JSON.generate({ generated: Time.now.utc.strftime("%FT%TZ"), cells: cells }).gsub("</", '<\/')
File.write(options[:out], template.sub("__DATA__", payload))

by_cut = cells.group_by { |c| c[:cut] }.transform_values(&:size).map { |k, v| "#{k} #{v}" }.join(" · ")
puts "wrote #{options[:out]} — #{cells.size} cells (#{by_cut})"
