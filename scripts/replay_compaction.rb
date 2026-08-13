# frozen_string_literal: true

# Real-replay measurement of the C3 criterion — "context tokens drop on a REAL
# replay" (the datum that decides F5, LLM compaction). It replays every session
# of a production store through the REAL history path (Context::Providers::
# Session -> ContextBuilder -> TokenEstimator), once with tool_output_compression
# OFF (what production ran, cross-checked against the recorded context_traces)
# and once ON (the counterfactual), turn by turn, and reports:
#
#   · fidelity  — how close the OFF replay is to the recorded traces (the proof
#     the replay is real, not synthetic)
#   · delta     — history tokens per turn with the mechanical dedupe ON vs OFF
#   · pressure  — used vs the deployment's real cap at the last turn, off vs on
#   · slope     — history growth in tokens/turn (the F5 signal: linear growth
#     means the cap WILL be reached — compression only moves the turn count)
#
# Usage:
#   bundle exec ruby scripts/replay_compaction.rb <store.db> [--top N]
#
# Read-only (SQLite mode=ro), provider-free, no API key: the replay is the
# context assembly, which is where the token count is decided — the model sees
# exactly the package this script reconstructs.
#
# History prefix model (from the engine): the session holds COMPLETED turns
# only (persist_turn appends after the turn); at turn N's context build the
# session contains turns 1..N-1. Each turn's transcript starts with its user
# message, so turn N's history = messages[0 ... index_of_user_message_N].

if %w[-h --help].include?(ARGV[0])
  puts File.read(__FILE__).lines.drop(1).drop_while { |l| l.strip.empty? }
           .take_while { |l| l.start_with?("#") }.map { |l| l.sub(/^# ?/, "") }.join
  exit 0
end

require_relative "../lib/insika"
require "async"
require "json"
require "sqlite3"

STORE_PATH = ARGV[0]
abort "usage: bundle exec ruby scripts/replay_compaction.rb <store.db> [--top N]" unless STORE_PATH

TOP = (i = ARGV.index("--top")) ? Integer(ARGV[i + 1] || "10") : 10

db = SQLite3::Database.new(STORE_PATH, readonly: true)
sessions_raw = db.execute("select key, value from kv where scope = ?", ["sessions"])
traces_raw = db.execute("select key, value from kv where scope = ?", ["context_traces"])

traces = {}
traces_raw.each { |sid, json| traces[sid] = JSON.parse(json) }

sessions = sessions_raw.filter_map do |key, json|
  rec = JSON.parse(json)
  msgs = rec["messages"] || []
  users = msgs.each_index.select { |i| msgs[i]["role"] == "user" }
  next if users.empty?

  [key.delete_prefix("session:"), msgs, users]
end

noop_events = Object.new
def noop_events.emit(_event) = nil

replay_store = Object.new
def replay_store.find(_id) = @session
def replay_store.session=(session)
  @session = session
end

off_profile = Insika::AgentProfile.build(id: "replay", model: "deepseek-chat", provider: :deepseek,
                                         tool_output_compression: false, limits: { context_budget: 60_000 })
on_profile = Insika::AgentProfile.build(id: "replay", model: "deepseek-chat", provider: :deepseek,
                                        tool_output_compression: true, limits: { context_budget: 60_000 })
provider = Insika::Context::Providers::Session.new(session_store: replay_store)
off_builder = Insika::ContextBuilder.new(providers: [provider], event_stream: noop_events)
on_builder = Insika::ContextBuilder.new(providers: [provider], event_stream: noop_events)

results = {}
Async do
  sessions.each do |sid, msgs, user_idx|
    turns = user_idx.each_with_index.map do |ui, n|
      prefix = msgs[0...ui]
      sess = Insika::SessionStore::Session.new(id: sid, messages: prefix, vars: {},
                                               memory_refs: [], created_at: nil, updated_at: nil)
      replay_store.session = sess
      off_pkg = off_builder.call(Insika::ContextRequest.new(session: sess, profile: off_profile))
      on_pkg = on_builder.call(Insika::ContextRequest.new(session: sess, profile: on_profile))
      [n + 1, off_pkg.budget[:used], on_pkg.budget[:used]]
    end
    results[sid] = turns
  end
end

fidelity_errors = results.flat_map do |sid, turns|
  next [] unless (trace = traces[sid])

  trace_seq = trace.map { |e| e.dig("categories", "session", "tokens") }
  pairs = [turns.length, trace_seq.length].min
  (0...pairs).filter_map do |i|
    t = trace_seq[i]
    next unless t && t.positive? && turns[i][1].positive?

    (turns[i][1] - t).abs.to_f / t
  end
end

puts "store: #{STORE_PATH}"
puts "sessions replayed: #{results.size} · turns replayed: #{results.values.sum(&:length)}"
if fidelity_errors.empty?
  puts "fidelity vs recorded context_traces: no comparable turns"
else
  sorted = fidelity_errors.sort
  puts format("fidelity vs recorded context_traces: mean %.1f%% · median %.1f%% · p95 %.1f%%",
              fidelity_errors.sum / fidelity_errors.size * 100,
              sorted[fidelity_errors.size / 2] * 100,
              sorted[(fidelity_errors.size * 0.95).ceil - 1] * 100)
end
puts

touched = results.select { |_sid, turns| turns.any? { |_t, off, on| on < off } }
total_off = results.values.sum { |turns| turns.last[1] }
total_on = results.values.sum { |turns| turns.last[2] }
saved = total_off - total_on
puts "mechanical dedupe (tool_output_compression) on REAL replays:"
puts "  sessions where it changed any turn: #{touched.size}/#{results.size}"
puts format("  history tokens at the last turn, whole corpus: %d -> %d (saved %d, %.2f%%)",
            total_off, total_on, saved, total_off.zero? ? 0 : saved.to_f / total_off * 100)
puts

puts "per-session (top #{TOP} by last-turn history tokens, OFF):"
puts format("  %-36s %5s %8s %8s %7s", "session", "turns", "off", "on", "Δ%")
results.sort_by { |_sid, turns| -turns.last[1] }.first(TOP).each do |sid, turns|
  last = turns.last
  delta = last[1].zero? ? 0 : (last[2] - last[1]).to_f / last[1] * 100
  puts format("  %-36s %5d %8d %8d %+6.1f%%", sid[0, 36], turns.length, last[1], last[2], delta)
end
puts

slopes = results.values.select { |turns| turns.length >= 5 }.map do |turns|
  n = turns.length
  (turns.last[1] - turns.first[1]).to_f / [n - 1, 1].max
end
if slopes.empty?
  puts "growth slope: no session with >= 5 turns"
else
  puts format("history growth (OFF): mean %.0f tok/turn · max %.0f · over %d sessions with >=5 turns",
              slopes.sum / slopes.size, slopes.max, slopes.size)
end

# Budget pressure at the deployment's REAL cap — per session, from its OWN
# trace: the non-session categories (prompt+skill+request — pinned identity
# and loaded skills) are constant across turns; the session is the only
# growing part. `used` is what the builder charged against `cap`; eviction
# happens when used > cap (a session without a trace has no cap/baseline and
# is skipped here — the store mixes agents with different caps).
pressures = []
results.each do |sid, turns|
  next unless (trace = traces[sid]) && trace.any?

  baseline = trace.map { |e| e["used"].to_i - (e.dig("categories", "session", "tokens") || 0) }
                  .select(&:positive?)
  next if baseline.empty?

  cap = trace.map { |e| e["cap"].to_i }.tally.max_by { |_k, v| v }.first
  base = baseline.sort[baseline.size / 2]
  pressures << [sid, cap, base + turns.last[1], base + turns.last[2]]
end
if pressures.any?
  over_off = pressures.count { |_sid, cap, used_off, _on| used_off > cap }
  over_on = pressures.count { |_sid, cap, _off, used_on| used_on > cap }
  max_used = pressures.map { |_sid, cap, off, on| [off, on, cap] }.max_by { |off, on, _c| [off, on] }
  puts
  puts "budget pressure at each session's own recorded cap:"
  puts format("  sessions whose LAST turn exceeds the cap: %d/%d (off) -> %d/%d (on)",
              over_off, pressures.size, over_on, pressures.size)
  puts format("  worst last turn: %d tok used / cap %d (off)", max_used[0], max_used[2])
end
