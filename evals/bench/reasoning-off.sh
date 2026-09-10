#!/usr/bin/env bash
# The side arm, not a bench row: our own entry against itself with reasoning OFF, so
# the footnote can say whether medium buys accuracy on these twelve tasks or only
# output tokens. One harness, one scorecard — a cross of reasoning against the table
# is eight combinations and ~1500 cells, and reasoning is a deployment variable.
#
# Three rounds, same as the medium arm it is compared against: a single round is not
# a measurement here either, cells flip.
set -u
cd "$(dirname "$0")"
export BENCH_PRICE_PER_MTOK=0.10
export BENCH_PRICE_NOTE="deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: \$0.0886/M in, \$0.1772/M out, blended here at 9:1"
export BENCH_REASONING=off
export RUNS_ROOT="$PWD/runs-reasoning-off"
export BENCH_REPORT="$PWD/REPORT-reasoning-off.md"
# Both scorecards, so the arm closes the square: ours in A and B, at medium and at
# off. Without B the footnote can only say reasoning changed our parity row; with it
# the footnote can say whether reasoning changes what our own layer adds.
#
# Same guard as cut3.sh: a run that dies mid-arm must not print COMPLETO over the hole.
for card in A B; do
  if ! HARNESSES=insika SCORECARD=$card ROUNDS=3 ./run.sh; then
    echo "BRACO ABORTADO: placar $card saiu com erro — celulas faltando" >&2
    exit 1
  fi
done
echo "BRACO REASONING-OFF COMPLETO"
