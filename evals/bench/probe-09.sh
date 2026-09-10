#!/usr/bin/env bash
# One task, ten rounds, the two harnesses that never lost it. Our own row already has
# ten rounds of 09 from reasoning-probe.sh (7/10 at medium, 9/10 at off); at three
# rounds the whole table sat between 4/6 and 6/6, which cannot tell a better harness
# from a luckier one. Twenty cells buys the comparison.
#
# Scorecard B, the same card our ten rounds ran under.
set -u
cd "$(dirname "$0")"
export BENCH_PRICE_PER_MTOK=0.10
export BENCH_PRICE_NOTE="deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09"
export TASKS_GLOB='09-*.yml'
export RUNS_ROOT="$PWD/runs-probe-09"
export BENCH_REPORT="$PWD/REPORT-probe-09.md"

if ! HARNESSES="hermes pi" SCORECARD=B ROUNDS=10 ./run.sh; then
  echo "PROBE 09 ABORTADA — celulas faltando" >&2
  exit 1
fi

ruby -rjson -e '
def rate(glob)
  cells = Dir.glob(glob).flat_map { |f| j = JSON.parse(File.read(f)); j["cases"] || [j] }
  cells.empty? ? nil : [cells.count { |c| c["pass"] }, cells.size]
end
puts "", "09-uma-vez-so, placar B, 10 rounds"
puts ""
rows = { "hermes" => rate("runs-probe-09/B/hermes/09-*-r*.json"),
         "pi" => rate("runs-probe-09/B/pi/09-*-r*.json"),
         "insika (medium)" => rate("runs-probe-medium/B/insika/09-*-r*.json"),
         "insika (off)" => rate("runs-probe-off/B/insika/09-*-r*.json") }
rows.each { |n, r| puts format("  %-18s %s", n, r ? format("%2d/%-2d", r[0], r[1]) : "  —") }
puts ""
'
echo "PROBE 09 COMPLETA"
