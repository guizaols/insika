# frozen_string_literal: true

# Session-level load benchmark — drives a FULL multi-message session (the 7-step
# flow below) through POST /v1/responses at rising levels of CONCURRENT SESSIONS,
# in two client modes:
#
#   stream  one message at a time on POST /v1/responses (SSE): consume the whole
#           reply, then send the next message. The classic request/response
#           consumer — and how a typical chat consumer drives the engine.
#   steer   the fast-typing WhatsApp user: message 1 opens its SSE stream on
#           /v1/responses while messages 2..7 are fired --gap ms apart WITHOUT
#           waiting, on POST /v1/messages?stream=false — the ONLY JSON surface
#           that carries the verdict (/v1/responses is frozen SSE and never
#           joins). Each answers 200 {steered:true} / {merged:true} when the
#           engine absorbs it into the running turn, or an aggregated
#           reply when it started/queued its own turn. The verdict mix is
#           counted, so the report shows how the agent's queue policy actually
#           behaved under load.
#
# It answers the question loadtest.rb cannot: loadtest.rb fires INDEPENDENT
# single-message turns; this script keeps one `user` (session) per lane and
# measures the whole journey — per-step latency, session wall-clock, and the
# steer verdict mix — as session concurrency grows.
#
# Session flow (every session, in order; the messages are the customer's):
#   1 greeting        "Olá"
#   2 cep_invalid     "82540000"   (set_location with an invalid CEP)
#   3 cep_valid       "20761121"   (set_location with a valid CEP)
#   4 search_corporal "Quero ver os hidratantes corporais para pele seca"
#   5 search_maos     "Quero ver os hidratantes de mão"
#   6 search_perfume  "Quero ver perfumes masculinos amadeirados"
#   7 faq_pagamento   "Posso pagar no boleto?"
#
# Usage:
#   # local — engine serving a deployment on :9292 (the default URL):
#   bundle exec ruby scripts/loadtest_session.rb --mode stream --levels 1,10
#   # Railway — point the SAME script at the deployed service:
#   INSIKA_URL=https://<service>.up.railway.app OPENCLAW_GATEWAY_TOKEN=... \
#     bundle exec ruby scripts/loadtest_session.rb --mode both
#   # web — the real production ingress (a consumer app on :3000, engine on :9292):
#   bundle exec ruby scripts/loadtest_session.rb --surface web \
#     --widget-id <widget-id> --mode stream --levels 1,10
#
# Flags:
#   --agent ID          agent id (sent as model: "openclaw:<id>")  (default: demo)
#   --surface S         engine | web                               (default: engine)
#                         engine = hits the insika directly (POST /v1/responses +
#                                  /v1/messages?stream=false)
#                         web    = the production path through a consumer's
#                                  widget API (POST /api/widget/sessions, then
#                                  .../messages → the consumer's pipeline →
#                                  engine → tools). Needs the consumer app.
#   --widget-id ID      the store's StoreConfig.widget_id (required with --surface web)
#   --mode M            stream | steer | both                      (default: both)
#   --levels a,b,c      concurrent-session sweep                   (default: 1,10,50,100,300,500,1000)
#   --iterations N      repeat each level N times; samples merge   (default: 1)
#   --gap MS            steer mode: delay between the 7 sends      (default: 800)
#   --timeout SECONDS   per-request read timeout                   (default: 120)
#   --url URL           base URL (default: $INSIKA_URL || http://localhost:9292)
#   --json              emit the report as JSON instead of text
#   --dry-run           print the plan + a sample request and exit (no traffic)
#   --help              show this help and exit
#
# Environment:
#   INSIKA_URL                base URL of the engine (overridden by --url)
#   OPENCLAW_GATEWAY_TOKEN    Bearer for /v1/responses; falls back to ADMIN_TOKEN,
#                             then "local-demo"
#
# Notes:
#   · Stream sessions use a fresh `user` id each; steer sessions create a real
#     session via POST /v1/sessions. Either way sessions never share cart/CEP
#     state, so a level measures C real concurrent conversations, not cache hits.
#   · A level runs all its sessions AT ONCE (C threads; steer adds one burst
#     thread per session). Level 1000 therefore means 1000–2000 local threads —
#     fine for I/O-bound Net::HTTP, but watch RAM on small machines.
#   · Steer mode measures until every REQUEST returned. Messages the engine
#     could not absorb are released as a follow-up turn AFTER
#     that no request observes — that tail is server-side by design.
#   · Real turns call the LLM provider: the full sweep is (1+10+...+1000)×7
#     turns per mode. Narrow --levels for a quick check.

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require "net/http"
require "uri"
require "json"

# --- flag parsing (--name value / boolean --name), same shape as bench.rb -----
BOOL_FLAGS = %w[json dry-run].freeze
VALUE_FLAGS = %w[agent mode levels iterations gap timeout url surface widget-id].freeze
KNOWN_FLAGS = (BOOL_FLAGS + VALUE_FLAGS).freeze

args = {}
i = 0
while i < ARGV.length
  tok = ARGV[i]
  abort "loadtest_session: expected a --flag, got #{tok.inspect} (see --help)" unless tok.start_with?("--")
  key = tok.sub(/^--/, "")
  abort "loadtest_session: unknown flag --#{key} (see --help)" unless KNOWN_FLAGS.include?(key)
  nxt = ARGV[i + 1]
  if BOOL_FLAGS.include?(key)
    args[key] = true
    i += 1
  elsif nxt.nil? || nxt.start_with?("--")
    abort "loadtest_session: --#{key} needs a value"
  else
    args[key] = nxt
    i += 2
  end
end

def positive_int(args, key, default)
  raw = args[key] || default
  n = Integer(raw)
  raise ArgumentError if n <= 0

  n
rescue ArgumentError, TypeError
  abort "loadtest_session: --#{key} must be a positive integer (got #{raw.inspect})"
end

AGENT = (args["agent"] || "demo").strip
abort "loadtest_session: --agent resolved to empty" if AGENT.empty?

SURFACE = args["surface"] || "engine"
unless %w[engine web].include?(SURFACE)
  abort "loadtest_session: --surface must be engine|web (got #{SURFACE.inspect})"
end
WIDGET_ID = args["widget-id"]
if SURFACE == "web" && WIDGET_ID.to_s.strip.empty?
  abort "loadtest_session: --surface web needs --widget-id (the store's StoreConfig.widget_id)"
end

MODE = args["mode"] || "both"
MODES = MODE == "both" ? %w[stream steer] : [MODE]
unless (MODES - %w[stream steer]).empty?
  abort "loadtest_session: --mode must be stream|steer|both (got #{MODE.inspect})"
end

LEVELS = (args["levels"] || "1,10,50,100,300,500,1000").split(",").map do |s|
  n = Integer(s.strip)
  raise ArgumentError if n <= 0

  n
rescue ArgumentError, TypeError
  abort "loadtest_session: --levels must be positive integers, comma-separated (got #{s.inspect})"
end
abort "loadtest_session: --levels resolved to an empty list" if LEVELS.empty?

ITERS = positive_int(args, "iterations", "1")
TIMEOUT = positive_int(args, "timeout", "120")
GAP = begin
  n = Integer(args["gap"] || "800")
  raise ArgumentError if n.negative?

  n
rescue ArgumentError, TypeError
  abort "loadtest_session: --gap must be a non-negative integer (got #{args['gap'].inspect})"
end

TOKEN = ENV["OPENCLAW_GATEWAY_TOKEN"] || ENV["ADMIN_TOKEN"] || "local-demo"
BASE = (args["url"] || ENV["INSIKA_URL"] || ENV["HARNESS_URL"] ||
        (SURFACE == "web" ? "http://localhost:3000" : "http://localhost:9292")).sub(%r{/$}, "")

FLOW = [
  ["greeting",        "Olá"],
  ["cep_invalid",     "82540000"],
  ["cep_valid",       "20761121"],
  ["search_corporal", "Quero ver os hidratantes corporais para pele seca"],
  ["search_maos",     "Quero ver os hidratantes de mão"],
  ["search_perfume",  "Quero ver perfumes masculinos amadeirados"],
  ["faq_pagamento",   "Posso pagar no boleto?"]
].freeze

RUN_ID = "#{Process.pid}-#{Time.now.to_i}"

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Interpolated percentile (same method as scripts/loadtest.rb).
def pct(sorted, p)
  return 0.0 if sorted.empty?

  r = (p / 100.0) * (sorted.length - 1)
  lo = sorted[r.floor]
  hi = sorted[r.ceil]
  (lo + (hi - lo) * (r - r.floor)).round(1)
end

# --- plan / dry-run -----------------------------------------------------------
sessions_per_mode = ITERS * LEVELS.sum
turns_per_mode = sessions_per_mode * FLOW.length
surface_note = SURFACE == "web" ? " surface=web widget=#{WIDGET_ID}" : " surface=engine"
plan = "loadtest_session -> #{BASE} | agent=#{AGENT}#{surface_note} mode=#{MODES.join('+')} " \
       "levels=#{LEVELS.join(',')} iters=#{ITERS} | sessions/mode=#{sessions_per_mode} " \
       "turns/mode=#{turns_per_mode} gap=#{GAP}ms timeout=#{TIMEOUT}s"

if args.key?("dry-run")
  masked = TOKEN.length > 8 ? "#{TOKEN[0, 4]}…#{TOKEN[-2, 2]}" : "***"
  puts plan
  puts "-" * 60
  puts "dry-run — no requests sent. Session flow (#{FLOW.length} steps per session):"
  FLOW.each_with_index { |(label, msg), idx| puts "  #{idx + 1}. #{label.ljust(15)} #{msg.inspect}" }
  puts "-" * 60
  if SURFACE == "web"
    puts "sample requests (the consumer's widget API — the production ingress):"
    puts "  POST #{URI.join(BASE + '/', 'api/widget/sessions')}"
    puts "  body: #{JSON.generate(widget_id: WIDGET_ID, visitor_id: "ltss-w-#{RUN_ID}-0-0")}"
    puts "  then per step: POST /api/widget/sessions/<token>/messages " \
         "body: #{JSON.generate(content: FLOW.first[1])}"
    puts "  steer mode: steps 2..7 fired #{GAP}ms apart (no verdict on this surface)"
  else
    sample = JSON.generate(model: "openclaw:#{AGENT}", user: "ltss-s-#{RUN_ID}-0-0",
                           stream: true, input: FLOW.first[1])
    puts "sample request:"
    puts "  POST #{URI.join(BASE + '/', 'v1/responses')}"
    puts "  Authorization: Bearer #{masked}"
    puts "  body (stream mode + steer step 1): #{sample}"
    puts "  steer steps 2..7: POST /v1/messages?stream=false fired #{GAP}ms apart, " \
         "verdicts steered/merged/turn counted"
  end
  exit 0
end

# --- one request ---------------------------------------------------------------
# Shared HTTP plumbing: one POST, whole body read, never raises. ttfb = first
# response byte.
def post(uri, body, accept: nil)
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"] = "application/json"
  req["Accept"] = accept if accept
  req.body = JSON.generate(body)

  t0 = mono
  ttfb = nil
  status = nil
  buf = +""
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.read_timeout = TIMEOUT
  http.open_timeout = 10
  http.start do
    http.request(req) do |res|
      status = res.code.to_i
      return { ok: false, status: status, total: (mono - t0) * 1000.0 } unless status.between?(200, 299)

      res.read_body do |chunk|
        ttfb ||= mono - t0
        buf << chunk
      end
    end
  end
  { ok: true, status: status, ttfb: ttfb && (ttfb * 1000.0), total: (mono - t0) * 1000.0, body: buf }
rescue StandardError => e
  { ok: false, error: e.class.to_s, total: 0.0 }
end

# POST /v1/responses (SSE; stream mode + steer step 1). Keeps the last usage /
# timing carried by a response.* frame (same extraction as scripts/loadtest.rb).
def post_sse(user, message)
  r = post(URI.join(BASE + "/", "v1/responses"),
           { model: "openclaw:#{AGENT}", user: user, stream: true, input: message },
           accept: "text/event-stream")
  return r unless r[:ok]

  usage = nil
  timing = nil
  r[:body].scan(/^data: (.+)$/) do |(line)|
    line = line.strip
    next if line.empty? || line == "[DONE]"

    obj =
      begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
    u = obj.dig("response", "usage") || obj["usage"]
    usage = u if u
    tm = obj.dig("response", "timing")
    timing = tm if tm
  end
  r.merge(usage: usage, timing: timing)
end

# POST /v1/messages?stream=false (steer steps 2..7) — the verdict-carrying
# surface. verdict = steered|merged when the engine joined the message to another
# turn; "turn" when it ran/queued its own (the aggregated reply). A 200 carrying
# `error` (a cancelled/failed aggregated turn) is NOT ok.
def post_json(session_id, message)
  r = post(URI.join(BASE + "/", "v1/messages?stream=false"),
           { agent: AGENT, session_id: session_id, message: message })
  warn "DEBUG post_json #{message[0,20].inspect} -> #{r[:ok] ? r[:body].to_s[0, 120] : r.inspect}" if ENV["LT_DEBUG"]
  return r unless r[:ok]

  obj =
    begin
      JSON.parse(r[:body])
    rescue JSON::ParserError
      {}
    end
  verdict = obj["steered"] ? "steered" : (obj["merged"] ? "merged" : "turn")
  r.merge(verdict: verdict, ok: !obj["error"], error: obj.dig("error", "message"))
end

# POST /v1/sessions — steer mode correlates by an explicit session id (the
# /v1/messages surface does not create sessions). -> [id, nil] or [nil, reason].
def create_session
  r = post(URI.join(BASE + "/", "v1/sessions"), {})
  return [nil, r[:status] ? "http #{r[:status]}" : (r[:error] || "unknown")] unless r[:ok]

  id =
    begin
      JSON.parse(r[:body]).dig("session", "id")
    rescue JSON::ParserError
      nil
    end
  id ? [id, nil] : [nil, "bad session payload"]
end

# --- sessions -------------------------------------------------------------------
# stream mode: strictly sequential — the next message only leaves after the whole
# SSE reply of the previous one was consumed.
def stream_session(user)
  started = mono
  steps = FLOW.to_h do |label, message|
    [label, post_sse(user, message)]
  end
  { ok: steps.values.all? { |r| r[:ok] }, wall: (mono - started) * 1000.0, steps: steps }
end

# steer mode: message 1 opens its SSE stream in the session thread (the reply of
# the turn that absorbs the burst rides THIS stream) while a burst thread fires
# messages 2..7 --gap ms apart on the verdict-carrying JSON surface. Session wall
# = until message 1's stream completed AND every burst request returned.
def steer_session(_user)
  started = mono
  session_id, setup_error = create_session
  return { ok: false, wall: (mono - started) * 1000.0, steps: {}, setup_error: setup_error } if session_id.nil?

  gap_s = GAP / 1000.0
  burst = Thread.new do
    sleep(gap_s) # let message 1 reach the server first so it owns the turn
    FLOW.drop(1).map do |label, message|
      r = post_json(session_id, message)
      sleep(gap_s)
      [label, r]
    end
  end
  first_label, first_message = FLOW.first
  first = post_sse(session_id, first_message)
  steps = { first_label => first }.merge(burst.value.to_h)
  { ok: steps.values.all? { |r| r[:ok] }, wall: (mono - started) * 1000.0, steps: steps }
end

# --- web surface: the production ingress through a consumer's widget API -------
# POST /api/widget/sessions creates the widget session (and the conversation on
# first message); POST .../messages runs the consumer's whole pipeline (→ engine
# → tools) and answers 201 with the assistant message, synchronously. No verdict
# exists on this surface — steer here measures what a fast-typing visitor
# actually gets today (each burst message is a full pipeline run of its own).

# -> [token, nil] or [nil, reason]
def web_create_session(visitor)
  r = post(URI.join(BASE + "/", "api/widget/sessions"),
           { widget_id: WIDGET_ID, visitor_id: visitor })
  return [nil, r[:status] ? "http #{r[:status]}" : (r[:error] || "unknown")] unless r[:ok]

  token =
    begin
      JSON.parse(r[:body])["token"]
    rescue JSON::ParserError
      nil
    end
  token ? [token, nil] : [nil, "bad widget session payload"]
end

def web_send(token, message)
  post(URI.join(BASE + "/", "api/widget/sessions/#{token}/messages"), { content: message })
end

def web_stream_session(visitor)
  started = mono
  token, setup_error = web_create_session(visitor)
  return { ok: false, wall: (mono - started) * 1000.0, steps: {}, setup_error: setup_error } if token.nil?

  steps = FLOW.to_h { |label, message| [label, web_send(token, message)] }
  { ok: steps.values.all? { |r| r[:ok] }, wall: (mono - started) * 1000.0, steps: steps }
end

def web_steer_session(visitor)
  started = mono
  token, setup_error = web_create_session(visitor)
  return { ok: false, wall: (mono - started) * 1000.0, steps: {}, setup_error: setup_error } if token.nil?

  gap_s = GAP / 1000.0
  burst = Thread.new do
    sleep(gap_s) # let message 1 enter the pipeline first
    FLOW.drop(1).map do |label, message|
      r = web_send(token, message)
      sleep(gap_s)
      [label, r]
    end
  end
  first_label, first_message = FLOW.first
  first = web_send(token, first_message)
  steps = { first_label => first }.merge(burst.value.to_h)
  { ok: steps.values.all? { |r| r[:ok] }, wall: (mono - started) * 1000.0, steps: steps }
end

# --- one level: LEVEL sessions at once, ITERS times ------------------------------
def run_level(mode, level)
  sessions = []
  started = mono
  ITERS.times do |it|
    threads = Array.new(level) do |idx|
      user = "ltss-#{mode[0]}-#{RUN_ID}-#{level}-#{it * level + idx}"
      Thread.new do
        case [SURFACE, mode]
        when ["engine", "stream"] then stream_session(user)
        when ["engine", "steer"]  then steer_session(user)
        when ["web", "stream"]    then web_stream_session(user)
        else                           web_steer_session(user)
        end
      end
    end
    threads.each { |t| sessions << t.value }
  end
  wall = mono - started

  ok = sessions.select { |s| s[:ok] }
  walls = sessions.map { |s| s[:wall] }.sort
  per_step = FLOW.map do |label, _|
    rs = sessions.filter_map { |s| s.dig(:steps, label) }
    totals = rs.filter_map { |r| r[:total] if r[:ok] }.sort
    ttfbs = rs.filter_map { |r| r[:ttfb] }.sort
    entry = { step: label, ok: rs.count { |r| r[:ok] }, n: rs.length,
              p50: pct(totals, 50), p95: pct(totals, 95) }
    entry[:ttfb50] = pct(ttfbs, 50) unless ttfbs.empty?
    entry[:errors] = rs.count { |r| !r[:ok] }
    entry
  end
  verdicts = nil
  if mode == "steer"
    verdicts = Hash.new(0)
    sessions.each do |s|
      s[:steps].each_value { |r| verdicts[r[:verdict]] += 1 if r[:ok] && r[:verdict] }
    end
  end
  timings = sessions.flat_map { |s| s[:steps].values.filter_map { |r| r[:timing] } }
  # WHY steps failed, tallied — a level of 350 instant failures is a config
  # problem (wrong agent / token / URL), not a measurement, and must say so.
  error_reasons = Hash.new(0)
  sessions.each do |s|
    if s[:setup_error]
      error_reasons[s[:setup_error]] += 1
      next
    end
    s[:steps].each_value do |r|
      error_reasons[r[:status] ? "http #{r[:status]}" : (r[:error] || "unknown")] += 1 unless r[:ok]
    end
  end
  { mode: mode, level: level, sessions: sessions.length, errors: sessions.length - ok.length,
    wall_s: wall.round(1), sessions_per_s: (sessions.length / wall).round(2),
    session_wall: { p50: pct(walls, 50), p95: pct(walls, 95), max: walls.last&.round(1) },
    steps: per_step, verdicts: verdicts, server_timings: timings.length,
    error_reasons: error_reasons }
end

# --- run + report ------------------------------------------------------------------
# --json: stdout belongs to the report alone; the plan and per-level progress go
# to stderr (same discipline as scripts/bench.rb's machine-readable mode).
json_out = args.key?("json")
json_out ? warn(plan) : puts(plan)
results = MODES.flat_map do |mode|
  LEVELS.map do |level|
    r = run_level(mode, level)
    if json_out
      # JSON report printed once at the end; keep the run quiet except progress.
      warn "done mode=#{mode} level=#{level} (#{r[:sessions]} sessions, #{r[:wall_s]}s)"
    else
      puts "-" * 66
      puts "mode=#{mode} level=#{level} — #{r[:sessions]} sessions " \
           "(errors: #{r[:errors]}) in #{r[:wall_s]}s (#{r[:sessions_per_s]} sessions/s)"
      w = r[:session_wall]
      puts "  session wall p50/p95/max: #{w[:p50]} / #{w[:p95]} / #{w[:max]} ms"
      unless r[:error_reasons].empty?
        puts "  step errors: #{r[:error_reasons].map { |k, v| "#{k}×#{v}" }.join(' ')}"
      end
      if mode == "stream"
        # TTFB is only meaningful on the engine surface (SSE); web answers a
        # synchronous JSON, so first byte ≈ total there.
        if SURFACE == "engine"
          puts "  step                ok/n        p50(ms)    p95(ms)  ttfb50(ms)"
          r[:steps].each do |s|
            printf("  %-18s  %4d/%-4d  %9.1f  %9.1f  %9.1f\n",
                   s[:step], s[:ok], s[:n], s[:p50], s[:p95], s[:ttfb50] || 0.0)
          end
        else
          puts "  step                ok/n        p50(ms)    p95(ms)"
          r[:steps].each do |s|
            printf("  %-18s  %4d/%-4d  %9.1f  %9.1f\n", s[:step], s[:ok], s[:n], s[:p50], s[:p95])
          end
        end
      else
        unless r[:verdicts].nil? || r[:verdicts].empty?
          puts "  verdicts: #{r[:verdicts].map { |k, v| "#{k}=#{v}" }.join(' ')}"
        end
        puts "  step                ok/n        p50(ms)    p95(ms)"
        r[:steps].each do |s|
          printf("  %-18s  %4d/%-4d  %9.1f  %9.1f\n", s[:step], s[:ok], s[:n], s[:p50], s[:p95])
        end
      end
      if r[:server_timings].positive?
        puts "  server timing present on #{r[:server_timings]} steps " \
             "(INSIKA_TURN_TIMING; see scripts/loadtest.rb for the split)"
      end
    end
    r
  end
end

if json_out
  puts JSON.pretty_generate(
    agent: AGENT, base: BASE, surface: SURFACE, widget_id: WIDGET_ID,
    modes: MODES, levels: LEVELS, iterations: ITERS,
    gap_ms: GAP, timeout_s: TIMEOUT, ruby: RUBY_DESCRIPTION,
    flow: FLOW.to_h, results: results
  )
else
  puts "-" * 66
  puts "done — #{results.sum { |r| r[:sessions] }} sessions, #{results.sum { |r| r[:errors] }} errors"
end
