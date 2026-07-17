# frozen_string_literal: true

# Load-test for the harness — hits POST /v1/responses DIRECTLY (the production
# path: achei-b2b/WhatsApp -> engine). Ruby equivalent of OpenClaw's
# loadtest-gateway.mjs; since the SSE contract is the SAME, it enables an
# apples-to-apples comparison of harness vs gateway.
#
# Per turn it measures: TTFB (time to first SSE byte), total time, and the
# `usage` (tokens + cache hit) from the last frame that carries usage. Fires N
# concurrent turns spread across the given agents. Output: P50/P95 of TTFB and
# total, mean tokens, cache-hit rate and error rate. Standard library only.
#
# Usage:
#   HARNESS_URL=http://localhost:9292 \
#   OPENCLAW_GATEWAY_TOKEN=xxx \
#   bundle exec ruby scripts/loadtest.rb \
#     --agents bia,agent-store-cacau-show --concurrency 16 --iterations 3 \
#     --message "hi, how are you?"
#
# Flags:
#   --agents a,b,c     comma-separated agent ids            (default: bia)
#   --concurrency N     concurrent turns per wave            (default: 8)
#   --iterations N      number of waves per agent            (default: 1)
#   --message TEXT      user message sent every turn         (default: greeting)
#   --timeout SECONDS   per-request read timeout             (default: 120)
#   --ports 9292,9293   round-robin across local processes   (default: HARNESS_URL)
#   --same-user         reuse the same user per agent (measures hot-conversation cache); default off
#   --dry-run           print the plan + a sample request and exit (no traffic)
#   --help              show this help and exit
#
# Environment:
#   HARNESS_URL                base URL of the engine        (default: http://localhost:9292)
#   OPENCLAW_GATEWAY_TOKEN     Bearer for /v1/responses; falls back to ADMIN_TOKEN, then "local-demo"

require "net/http"
require "uri"
require "json"

# The leading comment block (minus the frozen_string_literal magic line) is the help text.
USAGE = File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
            .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join

# --- flag parsing (supports "--flag value" and boolean "--flag") ---------------
# `same-user` is a boolean toggle (doc default: off) but tolerates a legacy value
# (`--same-user 1|0`). Crucially, a value flag NEVER swallows a following flag
# token (one that starts with "--"): otherwise `--same-user --dry-run` would eat
# the `--dry-run` and fire real traffic. A value flag with no value is left absent
# so defaults/warnings kick in downstream.
BOOL_FLAGS = %w[help dry-run same-user].freeze
VALUE_FLAGS = %w[agents concurrency iterations message timeout ports].freeze
KNOWN_FLAGS = (BOOL_FLAGS + VALUE_FLAGS).freeze

args = {}
i = 0
while i < ARGV.length
  tok = ARGV[i]
  unless tok.start_with?("--")
    warn "loadtest: ignoring stray argument #{tok.inspect} (flags look like --name value)"
    i += 1
    next
  end
  key = tok.sub(/^--/, "")
  warn "loadtest: unknown flag --#{key} (see --help)" unless KNOWN_FLAGS.include?(key)
  nxt = ARGV[i + 1]
  if BOOL_FLAGS.include?(key)
    if key == "same-user" && !nxt.nil? && !nxt.start_with?("--")
      args[key] = nxt          # legacy `--same-user 1|0`
      i += 2
    else
      args[key] = "true"       # toggle; do NOT consume a following flag
      i += 1
    end
  elsif nxt.nil? || nxt.start_with?("--")
    args[key] = nil            # value missing; do NOT consume a following flag
    i += 1
  else
    args[key] = nxt
    i += 2
  end
end

if args.key?("help")
  puts USAGE
  exit 0
end

def positive_int(args, key, default)
  # Flag given but with no value (e.g. `--concurrency` as the last token): warn and
  # fall back to the default instead of silently defaulting or crashing.
  if args.key?(key) && args[key].nil?
    warn "loadtest: --#{key} has no value, using default #{default}"
    return Integer(default)
  end

  raw = args[key] || default
  n = Integer(raw)
  raise ArgumentError if n <= 0

  n
rescue ArgumentError, TypeError
  abort "loadtest: --#{key} must be a positive integer (got #{raw.inspect})"
end

TOKEN = ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo"
base = (ENV["HARNESS_URL"] || "http://localhost:9292").sub(%r{/$}, "")
BASE_URLS = (args["ports"] ? args["ports"].split(",").map { |p| "http://localhost:#{p.strip}" } : [base])
AGENTS = (args["agents"] || "bia").split(",").map(&:strip).reject(&:empty?)
CONC = positive_int(args, "concurrency", "8")
ITERS = positive_int(args, "iterations", "1")
MESSAGE = args["message"] || "hi, how are you?"
TIMEOUT = positive_int(args, "timeout", "120")
SAME_USER = args.key?("same-user") && !%w[false 0 no].include?(args["same-user"].to_s.downcase)

abort "loadtest: --agents resolved to an empty list" if AGENTS.empty?

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# One turn: streaming POST; measures TTFB/total; extracts the last JSON with `usage`.
def run_turn(base_url, agent, idx)
  user = SAME_USER ? "loadtest-#{agent}" : "loadtest-#{agent}-#{idx}"
  uri = URI.join(base_url + "/", "v1/responses")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"] = "application/json"
  req["Accept"] = "text/event-stream"
  req.body = JSON.generate(model: "openclaw:#{agent}", user: user, stream: true, input: MESSAGE)

  t0 = mono
  ttfb = nil
  usage = nil
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.read_timeout = TIMEOUT
  http.open_timeout = 10

  status = nil
  http.start do
    http.request(req) do |res|
      status = res.code.to_i
      return { ok: false, status: status } unless status.between?(200, 299)

      buffer = +""
      res.read_body do |chunk|
        ttfb ||= mono - t0
        buffer << chunk
        # SSE frames: "data: {json}\n\n". Keep the last usage seen.
        while (i = buffer.index("\n\n"))
          frame = buffer.slice!(0..i + 1)
          frame.each_line do |line|
            next unless line.start_with?("data:")

            payload = line.sub(/^data:\s*/, "").strip
            next if payload.empty? || payload == "[DONE]"

            begin
              obj = JSON.parse(payload)
              u = obj.dig("response", "usage") || obj["usage"]
              usage = u if u
            rescue JSON::ParserError
              nil
            end
          end
        end
      end
    end
  end
  { ok: true, status: status, ttfb: (ttfb || (mono - t0)) * 1000.0, total: (mono - t0) * 1000.0, usage: usage }
rescue StandardError => e
  { ok: false, error: e.class.to_s }
end

def pct(sorted, p)
  return 0.0 if sorted.empty?

  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]; hi = sorted[r.ceil]
  (lo + (hi - lo) * (r - r.floor)).round(1)
end

total_turns = AGENTS.length * CONC * ITERS
puts "loadtest -> #{BASE_URLS.join(', ')} | agents=#{AGENTS.join(',')} conc=#{CONC} iters=#{ITERS} turns=#{total_turns}"

if args.key?("dry-run")
  sample = URI.join(BASE_URLS.first + "/", "v1/responses")
  body = JSON.generate(model: "openclaw:#{AGENTS.first}", user: "loadtest-#{AGENTS.first}-0",
                       stream: true, input: MESSAGE)
  masked = TOKEN.length > 8 ? "#{TOKEN[0, 4]}…#{TOKEN[-2, 2]}" : "***"
  puts "-" * 60
  puts "dry-run — no requests sent. Sample turn:"
  puts "  POST #{sample}"
  puts "  Authorization: Bearer #{masked}"
  puts "  Accept: text/event-stream"
  puts "  body: #{body}"
  puts "  same_user=#{SAME_USER} timeout=#{TIMEOUT}s ports=#{BASE_URLS.length}"
  exit 0
end

jobs = []
ITERS.times { |it| AGENTS.each { |a| CONC.times { |c| jobs << [a, it * CONC + c] } } }

results = []
mutex = Mutex.new
started = mono
jobs.each_slice(CONC).each_with_index do |batch, wave|
  threads = batch.map.with_index do |(agent, idx), i|
    Thread.new do
      base_url = BASE_URLS[(wave + i) % BASE_URLS.length]   # round-robin across ports
      r = run_turn(base_url, agent, idx)
      mutex.synchronize { results << r }
    end
  end
  threads.each(&:join)
end
wall = mono - started

ok = results.select { |r| r[:ok] }
errs = results.length - ok.length
ttfbs = ok.map { |r| r[:ttfb] }.compact.sort
totals = ok.map { |r| r[:total] }.compact.sort
toks = ok.map { |r| r.dig(:usage, "total_tokens") || r.dig(:usage, "output_tokens") }.compact
cache_hits = ok.map { |r| r.dig(:usage, "prompt_cache_hit_tokens") || r.dig(:usage, "cached_tokens") }.compact

puts "-" * 60
puts "turns ok:       #{ok.length}/#{results.length}  (errors: #{errs})"
puts "throughput:     #{(ok.length / wall).round(1)} turns/s  (wall #{wall.round(1)}s)"
puts "TTFB  p50/p95:  #{pct(ttfbs, 50)} / #{pct(ttfbs, 95)} ms"
puts "total p50/p95:  #{pct(totals, 50)} / #{pct(totals, 95)} ms"
puts "mean tokens:    #{toks.empty? ? '-' : (toks.sum.to_f / toks.length).round(0)}"
puts "mean cache hit: #{cache_hits.empty? ? '-' : (cache_hits.sum.to_f / cache_hits.length).round(0)} tokens"
