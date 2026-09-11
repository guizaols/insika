#!/usr/bin/env ruby
# frozen_string_literal: true

# Two cuts, cell by cell: for every scorecard, harness and task, how many cells
# passed before and after, and the difference. A task whose file changed between
# the two cuts is marked, because its rows are two different questions and the
# number between them is not a measurement.
#
#   ruby compare.rb cuts/2026-09-09/runs runs            # A and B
#   ruby compare.rb cuts/2026-09-09/runs runs --card B
require "json"
require "digest"
require "optparse"

opts = { card: nil }
OptionParser.new { |o| o.on("--card CARD") { |c| opts[:card] = c.upcase } }.parse!
before, after = ARGV
abort "usage: compare.rb <runs before> <runs after> [--card A|B]" unless before && after

def cells(root)
  Dir["#{root}/*/*/*-r*.json"].each_with_object(Hash.new { |h, k| h[k] = [0, 0] }) do |f, acc|
    card, harness = f.sub("#{root}/", "").split("/")[0, 2]
    JSON.parse(File.read(f))["cases"].each do |c|
      key = [card, harness, c["id"]]
      acc[key][0] += 1
      acc[key][1] += 1 if c["pass"]
    end
  end
end

# A task file that changed is stamped by its digest in the run when available;
# otherwise the current tasks/ tree is compared against the cut's own copy.
def changed_tasks(before_root)
  snapshot = File.join(File.dirname(before_root), "tasks")
  return {} unless Dir.exist?(snapshot)

  Dir["tasks/*.yml"].each_with_object({}) do |f, acc|
    old = File.join(snapshot, File.basename(f))
    acc[File.basename(f, ".yml")] = true if !File.exist?(old) || Digest::SHA256.file(old) != Digest::SHA256.file(f)
  end
end

b = cells(before)
a = cells(after)
changed = changed_tasks(before)
keys = (b.keys | a.keys).sort
keys = keys.select { |k| k[0] == opts[:card] } if opts[:card]

puts "| Card | Harness | Task | Before | After | Δ cells | |"
puts "| --- | --- | --- | --- | --- | --- | --- |"
keys.each do |key|
  card, harness, task = key
  bt, bp = b[key]
  at, ap = a[key]
  fmt = ->(p, t) { t.zero? ? "—" : "#{p}/#{t}" }
  delta = bt.zero? || at.zero? ? "—" : format("%+d", ap - bp)
  note = changed[task] ? "task changed — not comparable" : ""
  puts "| #{card} | #{harness} | #{task} | #{fmt.call(bp, bt)} | #{fmt.call(ap, at)} | #{delta} | #{note} |"
end
