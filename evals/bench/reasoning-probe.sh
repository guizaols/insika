#!/usr/bin/env bash
# The three tasks our row actually loses, at ten rounds each, with reasoning at medium
# and at off. Sixty cells against the same three tasks says more than the arm's
# thirty-six spread across twelve: each of these failed in one round out of three, so
# at three rounds the difference between 0 and 2 failures still fits inside variance.
#
# Scorecard B, because the decision this answers is a production one and B is what a
# store deployment actually ships.
#
#   05 — asked three questions where the task allows two
#   09 — read "adiciona logo por favor" as consent and closed the order
#   10 — said "adicionado ao carrinho" without calling add_to_cart
#
# All three are over-interpretation: inferring intent, narrating an action it did not
# take, elaborating past the limit. That is the failure shape more reasoning produces,
# which is the hypothesis here — not a bench row.
set -u
cd "$(dirname "$0")"
export BENCH_PRICE_PER_MTOK=0.10
export BENCH_PRICE_NOTE="deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: \$0.0886/M in, \$0.1772/M out, blended here at 9:1"
export TASKS_GLOB='05-*.yml 09-*.yml 10-*.yml'

for level in medium off; do
  export BENCH_REASONING=$level
  export RUNS_ROOT="$PWD/runs-probe-$level"
  export BENCH_REPORT="$PWD/REPORT-probe-$level.md"
  if ! HARNESSES=insika SCORECARD=B ROUNDS=10 ./run.sh; then
    echo "PROBE ABORTADA no nivel $level — celulas faltando" >&2
    exit 1
  fi
done

# The comparison the report tables cannot show: same task, same scorecard, one
# variable. Per task, so a single noisy task cannot carry the verdict.
ruby -rjson -e '
puts "", "task                      medium      off"
%w[05-abertura-sem-pedido 09-uma-vez-so 10-mudou-de-ideia].each do |id|
  row = %w[medium off].map do |lvl|
    # A report JSON carries its verdict in `cases`, not at the root: reading
    # ["pass"] off the top level yields nil for every file and prints 0/10 across
    # the board, which looks like a catastrophic result instead of a broken reader.
    cells = Dir.glob("runs-probe-#{lvl}/B/insika/#{id}-r*.json")
              .flat_map { |f| j = JSON.parse(File.read(f)); j["cases"] || [j] }
    pass = cells.count { |c| c["pass"] }
    cells.empty? ? "   —   " : format("%2d/%-2d", pass, cells.size)
  end
  puts format("%-24s  %-10s  %-10s", id, row[0], row[1])
end
puts ""
'
echo "PROBE REASONING COMPLETA"
