# frozen_string_literal: true

# Micro-bench of the CPU-BOUND hot path of a turn, WITHOUT a provider or I/O.
# Companion to `bench_store.rb` (which measures the SQLite write ceiling, an
# I/O-bound signal). This isolates the *interpreter* signal that
# says the Ruby-version bump / YJIT actually moves: JSON (de)serialization of the
# request/response envelope, SSE frame assembly (string building), and per-turn
# context/prompt assembly (hash/array churn). No sockets, no disk, no gems beyond
# stdlib `json` — so the ONLY variable between runs is the Ruby VM (and whether
# YJIT is on). Toggle YJIT with `RUBY_YJIT_ENABLE=1` (or `ruby --yjit`); the
# script prints `RubyVM::YJIT.enabled?` so a run is self-documenting.
#
# Usage:
#   ruby scripts/bench_cpu.rb [ITERATIONS] [WARMUP]
#   RUBY_YJIT_ENABLE=1 ruby scripts/bench_cpu.rb 40000 5000
#   defaults: 40000 iterations, 5000 warmup (warmup lets YJIT compile hot paths)
#
# Reports, per workload: iters/s and mean µs/iter over the timed window (after
# warmup), plus the aggregate. Higher iters/s is better; compare YJIT off vs on
# and Ruby version vs version.

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require "json"

ITERS = begin
  n = Integer(ARGV[0] || "40000")
  raise ArgumentError if n <= 0

  n
rescue ArgumentError
  abort "bench_cpu: ITERATIONS must be a positive integer (got #{ARGV[0].inspect})"
end

WARMUP = begin
  n = Integer(ARGV[1] || "5000")
  raise ArgumentError if n.negative?

  n
rescue ArgumentError
  abort "bench_cpu: WARMUP must be a non-negative integer (got #{ARGV[1].inspect})"
end

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# A turn-shaped request envelope (the kind the engine parses off /v1/responses
# and serializes back). Deliberately mid-size: a short history + tool defs + vars.
REQUEST = {
  "model" => "openclaw:bia",
  "stream" => true,
  "user" => "loadtest-bia-42",
  "messages" => Array.new(8) do |i|
    { "role" => i.even? ? "user" : "assistant",
      "content" => "message #{i}: the quick brown fox jumps over the lazy dog " * 4 }
  end,
  "tools" => Array.new(6) do |i|
    { "type" => "function",
      "function" => { "name" => "tool_#{i}", "description" => "does thing #{i}",
                      "parameters" => { "type" => "object",
                                        "properties" => { "q" => { "type" => "string" },
                                                          "n" => { "type" => "integer" } },
                                        "required" => ["q"] } } }
  end,
  "vars" => { "channel" => "whatsapp", "store_id" => "store-x", "locale" => "pt-BR" }
}.freeze

REQUEST_JSON = JSON.generate(REQUEST).freeze

# 1) Serialize the response envelope (assistant message + usage). Exercises
#    JSON.generate over nested hashes/arrays — the "context assembly/serialization".
def bench_serialize
  payload = {
    "id" => "resp_abc123",
    "object" => "response",
    "output" => [{ "role" => "assistant",
                   "content" => "here is a fairly long assistant reply " * 20 }],
    "usage" => { "input_tokens" => 1234, "output_tokens" => 567,
                 "total_tokens" => 1801, "cached_tokens" => 320 }
  }
  JSON.generate(payload)
end

# 2) Parse an incoming request envelope. Exercises the Prism-parsed JSON path.
def bench_parse
  JSON.parse(REQUEST_JSON)
end

# 3) Assemble the SSE frames the engine streams back (string building + interpolation
#    + chunking). This is the "event loop / streaming" CPU shape.
def bench_sse
  buf = +""
  20.times do |i|
    frame = { "type" => "response.output_text.delta",
              "delta" => "token#{i} ", "index" => i }
    buf << "event: message\n"
    buf << "data: "
    buf << JSON.generate(frame)
    buf << "\n\n"
  end
  buf
end

# 4) Context/prompt assembly: merge system + memory + skills + history into the
#    final message array (hash merge, array concat, string join) — the per-turn
#    "montagem de contexto/prompt" calls out.
SYSTEM = "You are a helpful assistant for a store. Follow the policy. " * 6
MEMORY = Array.new(5) { |i| "fact #{i}: the customer prefers option #{i}" }
def bench_context
  msgs = []
  msgs << { "role" => "system", "content" => SYSTEM + "\n" + MEMORY.join("\n") }
  REQUEST["messages"].each { |m| msgs << m.merge("ts" => "2026-07-17T00:00:00Z") }
  prompt = msgs.map { |m| "#{m['role'].upcase}: #{m['content']}" }.join("\n")
  { "messages" => msgs, "prompt_chars" => prompt.length,
    "tool_names" => REQUEST["tools"].map { |t| t["function"]["name"] } }
end

WORKLOADS = {
  "serialize" => method(:bench_serialize),
  "parse" => method(:bench_parse),
  "sse_frames" => method(:bench_sse),
  "context_asm" => method(:bench_context)
}.freeze

# One "iteration" runs every workload once — a rough proxy for the CPU work
# around a single turn (minus provider/I/O).
def one_iteration
  WORKLOADS.each_value(&:call)
end

puts "bench CPU (no provider/I/O) — #{ITERS} iters, #{WARMUP} warmup — " \
     "Ruby #{RUBY_VERSION} — YJIT: #{RubyVM::YJIT.enabled?}"
puts format("%-14s %14s %14s", "workload", "iters/s", "µs/iter")
puts "-" * 46

# Warmup: let YJIT compile the hot methods before we time anything.
WARMUP.times { one_iteration }

results = {}
WORKLOADS.each do |name, m|
  t0 = mono
  ITERS.times { m.call }
  dt = mono - t0
  results[name] = { ips: (ITERS / dt), us: (dt / ITERS) * 1_000_000.0 }
end

# Aggregate: full iteration (all workloads), timed together.
t0 = mono
ITERS.times { one_iteration }
agg_dt = mono - t0

results.each do |name, r|
  puts format("%-14s %14d %14.3f", name, r[:ips].round, r[:us])
end
puts "-" * 46
puts format("%-14s %14d %14.3f", "turn(all)", (ITERS / agg_dt).round, (agg_dt / ITERS) * 1_000_000.0)
