#!/usr/bin/env bash
# LOCAL multi-process load-test of the engine (Falcon --count N) over ONE SHARED
# SQLite file (WAL). Runs the load sweep against: (a) 1 worker = single-process
# baseline; (b) N workers = multi-process on the same box. Since the provider is
# the same in both runs, if the multi-process run recovers throughput the ceiling
# was CPU/event-loop, not the provider — and the "database is locked" count proves
# (or disproves) whether SQLite becomes the bottleneck under concurrency.
#
# Mirrors OpenClaw's scripts/loadtest-local.sh. Uses Bia (the default seeded
# agent) — requires DEEPSEEK_API_KEY.
#
# Usage:
#   DEEPSEEK_API_KEY=sk-... ./scripts/loadtest-local.sh [WORKERS] [CONCURRENCY]
#   e.g.: ./scripts/loadtest-local.sh 4 24
#
# Environment:
#   DEEPSEEK_API_KEY         required — real turns hit the provider
#   OPENCLAW_GATEWAY_TOKEN   Bearer for the sweep (falls back to ADMIN_TOKEN, then local-demo)
#   PORT                     bind port for the local Falcon (default: 9299)
#   AGENT                    agent id to load (default: bia)
set -u

case "${1:-}" in
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKERS="${1:-4}"
CONC="${2:-16}"
PORT="${PORT:-9299}"
AGENT="${AGENT:-bia}"
TOKEN="${OPENCLAW_GATEWAY_TOKEN:-${ADMIN_TOKEN:-local-demo}}"

case "$WORKERS$CONC" in
  *[!0-9]*)
    echo "ERROR: WORKERS and CONCURRENCY must be positive integers (got WORKERS=$WORKERS CONCURRENCY=$CONC)." >&2
    exit 2
    ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/insika-loadtest.XXXXXX")"
DB="$WORK/insika.db"

[ -f "$REPO/.env.local" ] && { set -a; . "$REPO/.env.local"; set +a; }
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "ERROR: set DEEPSEEK_API_KEY (real turns need the provider)." >&2; exit 1
fi

PID=""
cleanup() {
  [ -n "$PID" ] && { kill "$PID" 2>/dev/null; sleep 1; kill -9 "$PID" 2>/dev/null; }
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

wait_up() {
  i=0
  while [ "$i" -lt 60 ]; do
    curl -fsS "http://localhost:$PORT/up" >/dev/null 2>&1 && { echo "  ready (${i}s)"; return 0; }
    sleep 1; i=$((i+1))
  done
  echo "  did NOT become ready — see $LOG"; tail -8 "$LOG"; return 1
}

boot() {
  count="$1"; LOG="$WORK/falcon-$count.log"
  echo "=== booting Falcon --count $count (port $PORT, db $DB) ==="
  ( cd "$REPO" && INSIKA_DB="$DB" OPENCLAW_GATEWAY_TOKEN="$TOKEN" ADMIN_TOKEN="$TOKEN" \
      DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" RUBY_YJIT_ENABLE=1 \
      bundle exec falcon serve --bind "http://0.0.0.0:$PORT" --count "$count" \
      >"$LOG" 2>&1 ) & PID=$!
  wait_up || exit 1
}

sweep() {
  INSIKA_URL="http://localhost:$PORT" OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
    bundle exec ruby "$REPO/scripts/loadtest.rb" --agents "$AGENT" --concurrency "$CONC" --iterations 2
}

# `grep -c` already prints the count (0 when there are no matches); it just exits
# non-zero on zero matches, so `|| true` keeps the single "0" line instead of
# appending a second `echo 0`.
locks() { grep -c 'database is locked' "$1" 2>/dev/null || true; }

echo "############ BASELINE — 1 worker — conc $CONC ############"
boot 1; sweep
BASE_LOG="$LOG"
kill "$PID" 2>/dev/null; sleep 2; PID=""

echo ""
echo "############ MULTI — $WORKERS workers — conc $CONC ############"
boot "$WORKERS"; sweep
MULTI_LOG="$LOG"

echo ""
echo "=== 'database is locked' (expected 0 — WAL + busy_timeout) ==="
echo "  baseline (1):        $(locks "$BASE_LOG")"
echo "  multi ($WORKERS):    $(locks "$MULTI_LOG")"
