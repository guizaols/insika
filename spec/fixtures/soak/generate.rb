# frozen_string_literal: true

# Regenerates the committed soak fixtures (RFC-0026 techspec §5.7): one
# synthesized 72h run per verdict. The fold (Insika::Soak::Report) reads these
# files; the generator exists so a fixture is always reproducible, never
# hand-edited into place.
#
#   bundle exec ruby spec/fixtures/soak/generate.rb

require "json"
require "digest"
require "time"
require "fileutils"

ROOT = File.dirname(__FILE__)
ENVELOPE_PATH = File.join(ROOT, "envelope.md")

ENVELOPE_BODY = <<~MD
  # SOAK — fixture envelope

  Synthesized envelope for the report specs. Calibrated, 72h, tiny scale
  (4 turns/hour) so a fixture stays ~360 lines.

  ```yaml
  version: 1
  target: staging
  target_url_host: staging.example
  agent: soak-fixture
  tenant: soak

  duration_hours: 72
  warmup_hours: 6

  arrival: poisson
  turns_per_hour: 4
  session_turns: 2
  concurrency_cap: 2
  request_timeout_s: 120
  corpus: spec/fixtures/soak/corpus.txt

  web_concurrency: 1
  chat_rate_limit: 0
  agent_token_ceiling: 0
  turn_timing: required

  rss_growth_ratio: 1.15
  prep_p95_drift_ratio: 1.50
  restarts_max: 0
  error_rate_ceiling: 0.005
  no_usage_rate_ceiling: 0.002
  coverage_min_ratio: 0.95
  gap_seconds_max: 900
  hourly_turn_floor: 2

  rss_ceiling_mb: 900
  prep_p95_ceiling_ms: 10
  total_p95_ceiling_ms: 30_000

  report_only:
    - ttft_p95_ms
    - total_p95_hourly
    - rss_slope_mb_per_day
    - heap_growth_ratio
    - db_growth_mb
    - cost_usd
    - tokens_per_turn
  ```
MD

STARTED = "2026-08-20T09:00:00Z"
DURATION = 72
TURNS_PER_HOUR = 4
MB = 1_048_576

def at(hour, offset_s = 0)
  Time.parse(STARTED).utc + (hour * 3600 + offset_s)
end

def turn(hour, i, usage: true)
  t = at(hour, 300 + i * 900)
  rec = {
    "t" => "turn", "at" => t.iso8601, "lane" => hour * TURNS_PER_HOUR + i, "step" => 1,
    "corpus_line" => 1, "ok" => true, "status" => 200, "queued_ms" => 0,
    "ttfb_ms" => 731.2, "total_ms" => 2914.0,
    "timing" => { "prep_ms" => 0.4, "ttft_ms" => 707.0, "gen_ms" => 2206.0 },
    "error" => nil
  }
  rec["usage"] = { "total_tokens" => 48_211, "cached_tokens" => 27_004, "output_tokens" => 213 } if usage
  rec
end

def snapshot(hour, rss_bytes:, boot_id: "b1", pid: 1000, sha: nil, heap: 90_000)
  {
    "t" => "snapshot", "at" => at(hour).iso8601, "hour" => hour,
    "envelope_sha" => sha || ENVELOPE_SHA,
    "vitals" => {
      "boot_id" => boot_id, "pid" => pid, "started_at" => STARTED, "uptime_s" => hour * 3600,
      "version" => "0.2.0", "ruby" => "ruby 3.4.1", "yjit" => true,
      "rss_bytes" => rss_bytes,
      "gc" => { "heap_live_slots" => heap, "heap_free_slots" => 40_000, "heap_allocated_pages" => 500,
                "total_allocated_objects" => 1_000_000, "total_freed_objects" => 900_000,
                "major_gc_count" => hour / 6, "minor_gc_count" => hour * 10,
                "malloc_increase_bytes" => 0, "oldmalloc_increase_bytes" => 0 },
      "threads" => 8, "in_flight" => 1,
      "db_bytes" => { "db" => 8 * MB, "wal" => 1 * MB, "shm" => 32_768 },
      "at" => at(hour).iso8601
    },
    "error" => nil
  }
end

def flat_rss(hour) = ((512 + Math.sin(hour * 0.7) * 0.4) * MB).round

def leak_rss(hour) = ((180 + 3.05 * hour) * MB).round

def write(name, lines)
  File.write(File.join(ROOT, name), lines.map { |l| JSON.generate(l) }.join("\n") + "\n")
end

def base_header = {
  "t" => "header", "run_id" => "fixture-72h", "envelope_sha" => ENVELOPE_SHA,
  "envelope" => {}, "target_url" => "https://staging.example", "agent" => "soak-fixture",
  "seed" => 202_608_20, "runner_version" => "insika 0.2.0", "started_at" => STARTED
}

def standard_turns
  (0...DURATION).flat_map { |h| (0...TURNS_PER_HOUR).map { |i| turn(h, i) } }
end

def standard_snapshots(rss_fn, boot_fn: ->(_h) { "b1" }, pid_fn: ->(_h) { 1000 }, tamper: nil)
  (0...DURATION).map do |h|
    sha = (tamper && h == 40) ? "sha256:deadbeef" : nil
    snapshot(h, rss_bytes: rss_fn.call(h), boot_id: boot_fn.call(h), pid: pid_fn.call(h), sha: sha)
  end
end

File.write(ENVELOPE_PATH, ENVELOPE_BODY)
ENVELOPE_SHA = "sha256:#{Digest::SHA256.hexdigest(File.binread(ENVELOPE_PATH))}"

write("green-72h.jsonl",
      [base_header] + standard_turns + standard_snapshots(->(h) { flat_rss(h) }) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

write("leak.jsonl",
      [base_header] + standard_turns + standard_snapshots(->(h) { leak_rss(h) }) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

write("restart.jsonl",
      [base_header] + standard_turns +
      standard_snapshots(->(h) { flat_rss(h) }, boot_fn: ->(h) { h < 30 ? "b1" : "b2" }) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

write("worker-respawn.jsonl",
      [base_header] + standard_turns +
      standard_snapshots(->(h) { flat_rss(h) }, pid_fn: ->(h) { h < 30 ? 1000 : 2000 }) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

write("blocked.jsonl",
      [base_header] + standard_turns.map { |t| t.reject { |k, _| k == "usage" } } +
      standard_snapshots(->(h) { flat_rss(h) }) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

write("short.jsonl",
      [base_header] + (0...60).flat_map { |h| (0...TURNS_PER_HOUR).map { |i| turn(h, i) } } +
      standard_snapshots(->(h) { flat_rss(h) }).take(60) +
      [{ "t" => "end", "at" => at(60).iso8601, "reason" => "interrupted" }])

write("tampered.jsonl",
      [base_header] + standard_turns + standard_snapshots(->(h) { flat_rss(h) }, tamper: true) +
      [{ "t" => "end", "at" => at(DURATION).iso8601, "reason" => "complete" }])

File.write(File.join(ROOT, "corpus.txt"), <<~TXT)
  bom dia, tudo bem?
  queria saber o status do meu pedido
  o numero do pedido e 1234567
  pode me ajudar com uma troca?
TXT

puts "fixtures regenerated in #{ROOT}"
