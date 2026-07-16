#!/usr/bin/env bash
# Load-test LOCAL do multi-processo do harness (Falcon --count N) sobre UM MESMO
# SQLite (WAL). Roda o sweep de carga contra: (a) 1 worker = baseline single-proc;
# (b) N workers = multi-proc no mesmo box. Como o provider é o mesmo, se o multi
# recuperar throughput o teto era CPU/event-loop, não o provider — e a contagem de
# "database is locked" prova (ou não) se o SQLite vira gargalo sob concorrência.
#
# Espelha o scripts/loadtest-local.sh do OpenClaw. Usa a Bia (agente semeado por
# padrão) — precisa de DEEPSEEK_API_KEY.
#
# Uso:
#   DEEPSEEK_API_KEY=sk-... ./scripts/loadtest-local.sh [WORKERS] [CONCURRENCY]
#   ex.: ./scripts/loadtest-local.sh 4 24
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKERS="${1:-4}"
CONC="${2:-16}"
PORT="${PORT:-9299}"
AGENT="${AGENT:-bia}"
TOKEN="${OPENCLAW_GATEWAY_TOKEN:-${ADMIN_TOKEN:-local-demo}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-loadtest.XXXXXX")"
DB="$WORK/harness.db"

[ -f "$REPO/.env.local" ] && { set -a; . "$REPO/.env.local"; set +a; }
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "ERRO: defina DEEPSEEK_API_KEY (turnos reais precisam do provider)."; exit 1
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
  echo "  NÃO ficou ready — ver $LOG"; tail -8 "$LOG"; return 1
}

boot() {
  count="$1"; LOG="$WORK/falcon-$count.log"
  echo "=== subindo Falcon --count $count (porta $PORT, db $DB) ==="
  ( cd "$REPO" && HARNESS_DB="$DB" OPENCLAW_GATEWAY_TOKEN="$TOKEN" ADMIN_TOKEN="$TOKEN" \
      DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" RUBY_YJIT_ENABLE=1 \
      bundle exec falcon serve --bind "http://0.0.0.0:$PORT" --count "$count" \
      >"$LOG" 2>&1 ) & PID=$!
  wait_up || exit 1
}

sweep() {
  HARNESS_URL="http://localhost:$PORT" OPENCLAW_GATEWAY_TOKEN="$TOKEN" \
    bundle exec ruby "$REPO/scripts/loadtest.rb" --agents "$AGENT" --concurrency "$CONC" --iterations 2
}

locks() { grep -c 'database is locked' "$1" 2>/dev/null || echo 0; }

echo "############ BASELINE — 1 worker — conc $CONC ############"
boot 1; sweep
BASE_LOG="$LOG"
kill "$PID" 2>/dev/null; sleep 2; PID=""

echo ""
echo "############ MULTI — $WORKERS workers — conc $CONC ############"
boot "$WORKERS"; sweep
MULTI_LOG="$LOG"

echo ""
echo "=== 'database is locked' (esperado 0 — WAL + busy_timeout) ==="
echo "  baseline (1):        $(locks "$BASE_LOG")"
echo "  multi ($WORKERS):    $(locks "$MULTI_LOG")"
