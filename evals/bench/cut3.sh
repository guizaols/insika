#!/usr/bin/env bash
# The whole cut, idempotent: run.sh now skips any cell already on disk, so this can
# be launched again after an OOM kill and only the in-flight cell is lost.
set -u
cd "$(dirname "$0")"
export BENCH_PRICE_PER_MTOK=0.10
export BENCH_PRICE_NOTE="deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: \$0.0886/M in, \$0.1772/M out, blended here at 9:1"

# A scorecard that dies mid-run must stop the cut, not hand the next one the machine.
# `run.sh` runs under `set -e`, so one infrastructure failure ends it with cells still
# unmeasured — and this script used to walk on to the next card and print CUT3
# COMPLETO over the hole. It did: scorecard A once ended at cell 3 of 216 while B ran
# to completion beside it, and nothing in the output said so.
run_card() {
  SCORECARD="$1" ROUNDS=3 ./run.sh
  local status=$?
  [ $status -eq 0 ] && return 0
  echo "CUT3 ABORTADO: placar $1 saiu com status $status — celulas faltando, NAO publique" >&2
  exit 1
}

for card in A B; do run_card "$card"; done

export BENCH_PROMPT_FILE=./prompt/AGENTS-unguarded.md
export RUNS_ROOT="$PWD/runs-unguarded"
export BENCH_REPORT="$PWD/REPORT-unguarded.md"
export TASKS_GLOB='0[8]-*.yml 1[12]-*.yml'
for card in A B; do run_card "$card"; done
echo "CUT3 COMPLETO"
