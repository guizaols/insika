# frozen_string_literal: true

# Micro-bench of the WRITE CEILING of Stores::SQLite under N PROCESSES.
# Isolates the question "does SQLite hold up multi-process?" from LLM-provider
# noise: it measures raw write contention against the SAME file (WAL +
# busy_timeout + BEGIN IMMEDIATE + in-process semaphore — the harness's real
# production config).
#
# Each process opens its own handle on the SAME db and runs M write transactions
# (INSERT OR REPLACE, disjoint keys → measures WAL write serialization, which
# allows only 1 writer at a time on the file). Reports, per process count:
# aggregate throughput (writes/s), p50/p95/max latency and "database is locked"
# errors (expected ~0 thanks to busy_timeout; contention shows up as latency, not
# errors).
#
# Usage:
#   bundle exec ruby scripts/bench_store.rb [PROCS_CSV] [WRITES_PER_PROC]
#   e.g.: bundle exec ruby scripts/bench_store.rb 1,2,4,8 2000
#
# Does NOT touch your HARNESS_DB — uses a temp file isolated per round.

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require_relative "../lib/harness"
require "async"
require "json"
require "tmpdir"
require "fileutils"

def positive_int_list(raw)
  list = raw.split(",").map { |n| Integer(n.strip) }
  # An empty list (e.g. "" or ",") would silently run zero rounds and exit 0 —
  # abort with the same clear message instead.
  raise ArgumentError if list.empty? || list.any? { |x| x <= 0 }

  list
rescue ArgumentError
  abort "bench_store: PROCS must be a comma-separated list of positive integers (got #{raw.inspect})"
end

PROCS = positive_int_list(ARGV[0] || "1,2,4,8")
WRITES = begin
  n = Integer(ARGV[1] || "2000")            # writes per process
  raise ArgumentError if n <= 0

  n
rescue ArgumentError
  abort "bench_store: WRITES_PER_PROC must be a positive integer (got #{(ARGV[1]).inspect})"
end
# Payload ~ a typical record (session/checkpoint): a few hundred bytes.
PAYLOAD = {
  "messages" => Array.new(6) { { "role" => "user", "content" => "sample message with some text" } },
  "vars" => { "channel" => "bench", "store_id" => "store-x" },
  "updated_at" => "2026-07-16T00:00:00Z"
}.freeze

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def percentile(sorted, pct)
  return 0.0 if sorted.empty?

  rank = (pct / 100.0) * (sorted.length - 1)
  lo = sorted[rank.floor]
  hi = sorted[rank.ceil]
  (lo + (hi - lo) * (rank - rank.floor)).round(3)
end

# Runs `procs` processes each writing WRITES rows to the shared db. -> metrics.
def run_round(procs, db_path)
  result_dir = Dir.mktmpdir("bench-res")
  # Pre-initialize the file (DDL + WAL) in the PARENT: avoids the race of N
  # children running CREATE TABLE / PRAGMA WAL concurrently on a fresh db.
  Harness::Stores::SQLite.new(path: db_path).close

  started = mono

  pids = procs.times.map do |p|
    Process.fork do
      store = Harness::Stores::SQLite.new(path: db_path)
      lats = []
      locked = 0
      Sync do
        WRITES.times do |i|
          t0 = mono
          begin
            store.set("bench", "p#{p}-#{i}", PAYLOAD)
            lats << (mono - t0) * 1000.0            # ms
          rescue Harness::StoreError => e
            locked += 1 if e.message =~ /lock|busy/i
          end
        end
      end
      store.close
      File.write(File.join(result_dir, "#{p}.json"),
                 JSON.generate("count" => lats.length, "locked" => locked, "lats" => lats))
    end
  end
  pids.each { |pid| Process.wait(pid) }

  wall = mono - started
  lats = []
  count = 0
  locked = 0
  Dir[File.join(result_dir, "*.json")].each do |f|
    r = JSON.parse(File.read(f))
    count += r["count"]
    locked += r["locked"]
    lats.concat(r["lats"])
  end
  lats.sort!
  { procs: procs, wall: wall, count: count, locked: locked,
    throughput: (count / wall).round(0),
    p50: percentile(lats, 50), p95: percentile(lats, 95), max: (lats.last || 0).round(3) }
ensure
  FileUtils.remove_entry(result_dir) if result_dir && Dir.exist?(result_dir)
end

puts "bench SQLite (WAL) — #{WRITES} writes/proc, payload ~#{PAYLOAD.to_json.bytesize}B"
puts format("%-6s %10s %12s %10s %10s %10s %8s", "procs", "wall(s)", "writes/s", "p50(ms)", "p95(ms)", "max(ms)", "locked")
puts "-" * 74

PROCS.each do |n|
  Dir.mktmpdir("bench-db") do |dir|
    db = File.join(dir, "bench.db")
    m = run_round(n, db)
    puts format("%-6d %10.2f %12d %10.2f %10.2f %10.2f %8d",
                m[:procs], m[:wall], m[:throughput], m[:p50], m[:p95], m[:max], m[:locked])
  end
end
