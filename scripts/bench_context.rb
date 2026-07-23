# frozen_string_literal: true

# Micro-bench of the CONTEXT-BUILD cost per turn (item 34 / §13.1, action 1:
# "profile the assembly before caching — know WHERE the ms are").
#
# It isolates the LOCAL prefix-assembly cost (what the harness pays BEFORE the
# first LLM token, and what OpenClaw beats us on in TTFB) from any provider
# latency: no LLM is called. It seeds a realistic ~27k-token identity into a
# SQLite AgentFileStore (the production layout) and times, per turn:
#
#   · profile fetch  — StoredProfileSource#fetch (SQLite get + AgentProfile.build)
#   · prompt read    — Prompt provider alone (AgentFileStore read + concat + fragment)
#   · full build     — ContextBuilder#call (select -> produce -> estimate ->
#                      budget -> assemble), the real stage-2 cost
#   · cached build    — same, but with the static-prefix fragments memoized
#                      (the OPTIMISTIC target: what item 34's cache would buy)
#
# Reports p50/p95/mean per phase and the projected TTFB delta.
#
# Usage:
#   bundle exec ruby scripts/bench_context.rb [ITERS] [IDENTITY_TOKENS]
#   e.g.: bundle exec ruby scripts/bench_context.rb 500 27000
#
# Uses a temp SQLite file — does NOT touch your HARNESS_DB.

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require_relative "../lib/insika"
require "async"
require "tmpdir"
require "securerandom"

ITERS = Integer(ARGV[0] || "500")
IDENTITY_TOKENS = Integer(ARGV[1] || "27000")
AGENT_ID = "bench-agent"

# ~4 chars/token (the TokenEstimator's own ratio) — build an identity of the
# requested token size out of realistic prose lines (not one giant blob, so the
# concat/join cost is representative of a real multi-section pack).
def identity_text(tokens)
  target_chars = tokens * 4
  line = "You are a helpful store assistant. Follow the policy, cite the catalog, " \
         "never invent prices, and escalate when a human is required. "
  (line * ((target_chars / line.length) + 1))[0, target_chars]
end

# Minimal no-op collaborators (the bench measures assembly, not events/hooks).
event_stream = Object.new.tap { |o| def o.emit(_event) = nil }

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def stats(samples_ms)
  sorted = samples_ms.sort
  n = sorted.length
  pct = ->(p) { sorted[[(p * n).ceil - 1, 0].max] }
  { p50: pct.call(0.50), p95: pct.call(0.95),
    mean: samples_ms.sum / n, max: sorted.last }
end

def show(label, samples_ms)
  s = stats(samples_ms)
  printf("  %-14s p50=%7.3f ms   p95=%7.3f ms   mean=%7.3f ms   max=%7.3f ms\n",
         label, s[:p50], s[:p95], s[:mean], s[:max])
  s
end

Dir.mktmpdir do |dir|
  backend = Insika::Stores::SQLite.new(path: File.join(dir, "bench.db"))
  store = Insika::ConfigStore.new(store: backend)
  agent_files = Insika::AgentFileStore.new(config_store: store)
  profiles = Insika::StoredProfileSource.new(config_store: store)

  # Seed: one ~27k-token identity file + a profile that pins it (context_budget
  # generous so nothing is evicted — we measure assembly, not eviction).
  identity = identity_text(IDENTITY_TOKENS)
  agent_files.write(AGENT_ID, "IDENTITY.md", identity)
  profiles.put(Insika::AgentProfile.build(
                 id: AGENT_ID, model: "deepseek-chat", provider: :deepseek,
                 prompt_files: ["IDENTITY.md"], limits: { context_budget: 40_000 }
               ))

  prompt = Insika::Context::Providers::Prompt.new(agent_files: agent_files)
  builder = Insika::ContextBuilder.new(providers: [prompt], event_stream: event_stream)

  approx_chars = identity.length
  puts "bench_context: #{ITERS} iters · identity #{IDENTITY_TOKENS} tok " \
       "(~#{approx_chars} chars) · SQLite temp store"
  puts

  # A memoized static-prefix stand-in for the OPTIMISTIC (cached) path: the
  # Prompt provider's fragments computed ONCE, reused across turns. This is not
  # the real implementation — it is the ceiling the cache is chasing.
  cached_fragments = nil

  fetch_ms = []
  prompt_ms = []
  full_ms = []
  cached_ms = []

  Async do
    # Warm the store's page cache / any lazy init so iteration 1 isn't an outlier.
    profiles.fetch(AGENT_ID)
    req0 = Insika::ContextRequest.new(session: nil, message: "warm", profile: profiles.fetch(AGENT_ID),
                                       tenant: nil, vars: {}, checkpoint: nil)
    builder.call(req0)

    ITERS.times do
      t = monotonic
      profile = profiles.fetch(AGENT_ID)
      fetch_ms << (monotonic - t) * 1000

      req = Insika::ContextRequest.new(session: nil, message: "meu CEP é 30130-010, tem trufa?",
                                        profile: profile, tenant: nil, vars: {}, checkpoint: nil)

      t = monotonic
      prompt.call(req)
      prompt_ms << (monotonic - t) * 1000

      t = monotonic
      builder.call(req)
      full_ms << (monotonic - t) * 1000

      # Cached path: reuse the memoized static fragments, skip store read + concat.
      t = monotonic
      cached_fragments ||= prompt.call(req)
      _ = cached_fragments
      cached_ms << (monotonic - t) * 1000
    end
  end

  puts "Per-turn assembly cost (no LLM):"
  fetch = show("profile fetch", fetch_ms)
  show("prompt read", prompt_ms)
  full = show("full build", full_ms)
  cached = show("cached build", cached_ms)
  puts

  saved = full[:p50] - cached[:p50]
  puts format("Projected static-prefix saving (full - cached, p50): %.3f ms/turn", saved)
  puts format("Profile fetch is %.1f%% of full build (p50).", (fetch[:p50] / full[:p50]) * 100)
end
