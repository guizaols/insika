#!/usr/bin/env bash
# One row of the table at a time: for each harness, for each task — reset the store,
# run the turn through that harness's driver, dump the store, grade. Then
# `scorecard.rb` turns the per-run JSON into REPORT.md.
#
#   OPENROUTER_API_KEY=… BENCH_MODEL=… evals/bench/run.sh
#   HARNESSES=insika SCORECARD=B ROUNDS=3 evals/bench/run.sh
#
# A single run is not a measurement: cells flip between rounds, so the table counts
# CELLS (tasks x rounds) and ROUNDS is the floor, not a nicety.
#
# The reset is the whole point of the compose file: a task that passes because the
# previous one already created the order invalidates the table without anyone
# noticing.
set -euo pipefail

cd "$(dirname "$0")"
BENCH_DIR="$PWD"
REPO_ROOT="$(cd ../.. && pwd)"

# Only the entrants whose adapter exists. openclaw is wired; ours needs a deployment
# pointed at the bench store, and the rivals need their own `harnesses/<name>/driver`.
HARNESSES="${HARNESSES:-insika openclaw hermes pi opencode claude-code}"
# A: parity — same tools, same model, same prompt. B: out of the box, as each ships.
# The drivers read it from the environment, through compose, and configure their
# harness accordingly — it is not just a directory name.
SCORECARD="${SCORECARD:-A}"
export BENCH_SCORECARD="$SCORECARD"
# Rounds per harness. Three is the floor: one run is not a measurement.
ROUNDS="${ROUNDS:-3}"
TASKS_DIR="${TASKS_DIR:-$BENCH_DIR/tasks}"
# Which tasks this run covers. The unguarded-prompt cut only needs the tasks whose
# rule the prompt stopped carrying — running the other nine twice measures nothing
# and costs the same as running them once.
TASKS_GLOB="${TASKS_GLOB:-*.yml}"
# Where the cut lands. A second cut (a different shared prompt) gets its own root, so
# the two never share a table by accident.
RUNS_ROOT="${RUNS_ROOT:-$BENCH_DIR/runs}"
RUNS_DIR="$RUNS_ROOT/$SCORECARD"
# How the store hands over its own state for grading. The grader is not a harness:
# it reads the dumped truth, not the MCP surface the agent could have confused.
STORE_DUMP="${STORE_DUMP:-docker compose exec -T store dump-state}"

compose() { docker compose -f "$BENCH_DIR/compose.yml" "$@"; }

# Harnesses that cannot report which tools they called are declared HERE, once. Their
# tool-shaped graders are then reported as skipped instead of passed.
no_tools_flag() {
  case " ${BENCH_NO_TOOL_REPORTING:-} " in
    *" $1 "*) echo "--driver-no-tools" ;;
    *) echo "" ;;
  esac
}

mkdir -p "$RUNS_DIR"
shopt -s nullglob
# One or more patterns, each resolved against TASKS_DIR. Two traps, both silent:
# a bare "$TASKS_DIR"/$GLOB prefixes only the FIRST word of a multi-pattern filter,
# and splitting the variable with globbing on lets the shell expand the pattern
# against the CURRENT directory first — which is how "*.yml" once became compose.yml
# and the bench ran one task that does not exist.
set -f
read -ra patterns <<< "$TASKS_GLOB"
set +f
tasks=()
for pattern in "${patterns[@]}"; do tasks+=("$TASKS_DIR"/$pattern); done
[ ${#tasks[@]} -gt 0 ] || { echo "bench: no task in $TASKS_DIR" >&2; exit 1; }

for harness in $HARNESSES; do
  # Every entrant is driven the same way: `driver` inside its own container, reading
  # one JSON object on stdin. Nothing runs on the host, so no harness gets a shorter
  # path to the store than another.
  [ -f "$BENCH_DIR/harnesses/$harness/driver" ] || { echo "bench: no adapter at harnesses/$harness/driver" >&2; exit 1; }
  mkdir -p "$RUNS_DIR/$harness"

  for round in $(seq 1 "$ROUNDS"); do
  for task in "${tasks[@]}"; do
    id="$(basename "$task" .yml)"
    echo "== $SCORECARD | $harness | $id | round $round"
    report="$RUNS_DIR/$harness/$id-r$round.json"
    # Already measured, on an earlier attempt. A four-hour run on a machine that can
    # OOM has to be resumable, or every restart re-buys cells that are already on
    # disk — and re-running a cell is not free, it is a different sample.
    if [ -s "$report" ] && ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$report" 2>/dev/null; then
      echo "   (já medida, pulando)"
      continue
    fi

    compose down -v --remove-orphans >/dev/null 2>&1 || true
    # `down` returns before the daemon has finished removing the containers, and the
    # next `up` then dies on the name it is about to reuse — four hours in, on cell
    # 300, for no reason anyone can reproduce later. Wait for the project to be gone.
    #
    # The listing is not enough on its own: the daemon keeps the NAME reserved for a
    # moment after the container stops being listed, so this wait passes and `up`
    # still dies on "name already in use" — which is exactly how scorecard A lost 214
    # cells while B ran to completion beside it. Retry the `up` until the name frees.
    until [ -z "$(docker ps -aq --filter label=com.docker.compose.project=insika-bench)" ]; do sleep 0.5; done
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      compose up -d store "$harness" >/dev/null 2>&1 && break
      [ "$attempt" = 10 ] && { echo "bench: up falhou 10x para $harness" >&2; exit 1; }
      sleep 2
    done
    compose exec -T store wait-ready >/dev/null
    # A harness that needs one-off wiring ships a `setup` in its image; it runs here,
    # after the store is healthy and OUTSIDE the timed turn, so nobody's column
    # carries the cost of being plugged in.
    compose exec -T "$harness" sh -lc 'command -v setup >/dev/null 2>&1 && setup' >/dev/null 2>&1 || true

    # A repeat must not reuse a conversation id: a harness that kept the session
    # would answer round two from what round one taught it, and a 2.5s "answer"
    # looks exactly like a fast pass.
    convmap="$(mktemp)"
    printf '{"%s":"r%s-%s"}' "$id" "$round" "$id" > "$convmap"

    # The turn(s), through the driver; then the store is asked for its own state,
    # after the clock has stopped, so the dump never lands in the harness's time.
    # shellcheck disable=SC2046  # no_tools_flag is ours, and empty must vanish
    ruby "$REPO_ROOT/evals/run.rb" \
      --source dir --golden-dir "$TASKS_DIR" --id "$id" \
      --driver "docker compose -f $BENCH_DIR/compose.yml exec -T $harness driver" \
      $(no_tools_flag "$harness") \
      --conv-map "$convmap" \
      --store-dump "$STORE_DUMP" \
      --out "$report" \
      --transcripts "$RUNS_DIR/$harness/transcripts/r$round" \
      --no-judge || true   # a failing task is a row, not a reason to stop the run
    rm -f "$convmap"
  done
  done
done

compose down -v --remove-orphans >/dev/null 2>&1 || true
# A price turns tokens into a cost column. It is optional and it is dated on purpose:
# prices move, and a cost column without the date it was read is not a measurement.
price_args=""
[ -n "${BENCH_PRICE_PER_MTOK:-}" ] && price_args="--price-per-mtok $BENCH_PRICE_PER_MTOK --price-note ${BENCH_PRICE_NOTE:-unstated}"

# shellcheck disable=SC2086  # the flags are ours, not user text
ruby "$BENCH_DIR/scorecard.rb" --runs "$RUNS_ROOT" --out "${BENCH_REPORT:-$BENCH_DIR/REPORT.md}" $price_args
echo "report: ${BENCH_REPORT:-$BENCH_DIR/REPORT.md}"
