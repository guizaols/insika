#!/usr/bin/env bash
# Litestream restore drill (FOLLOWUP §12 G1 "done" gate).
#
# Proves the opt-in Litestream mechanism end-to-end using the REAL image
# (its litestream binary + deploy/litestream.yml + deploy/entrypoint.sh) against
# a local file:// replica — no cloud creds required. It:
#   1. seeds a marker row into a fresh harness.db (host sqlite3, WAL);
#   2. boots the image with Litestream ENABLED → replicates to a local replica;
#   3. wipes the data volume (simulating a lost box);
#   4. boots a SECOND container → entrypoint restores harness.db from the replica;
#   5. asserts the marker row survived AND /up is green.
#
# Requires: docker, sqlite3, curl. Usage:
#   scripts/litestream-restore-drill.sh [image-tag]   (default: harness:g1-drill)
set -euo pipefail

IMAGE="${1:-harness:g1-drill}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DATA="${WORK}/data"
REPLICA="${WORK}/replica"
mkdir -p "${DATA}" "${REPLICA}"
CID=""

cleanup() {
  [ -n "${CID}" ] && docker rm -f "${CID}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

log() { printf '\n\033[1;36m[drill]\033[0m %s\n' "$*"; }

# Litestream file:// replica + a marker the restored DB must still contain.
REPLICA_URL="file:///replica/harness"
MARKER="drill-$(date +%s)"

log "0/6 build image: ${IMAGE}"
docker build -q -t "${IMAGE}" "${REPO_ROOT}" >/dev/null

log "1/6 seed marker row into a fresh WAL db (host sqlite3)"
sqlite3 "${DATA}/harness.db" <<SQL
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS drill_marker (id INTEGER PRIMARY KEY, tag TEXT);
INSERT INTO drill_marker (tag) VALUES ('${MARKER}');
SQL
echo "  seeded tag=${MARKER}"

run_container() {
  # $1 = name suffix. Boots the image with the FULL entrypoint + Litestream on.
  # No DEEPSEEK key: the app boots /up green regardless (see docs/DEPLOY.md).
  docker run -d --name "harness-drill-$1" \
    -p 0:9292 \
    -v "${DATA}:/data" -v "${REPLICA}:/replica" \
    -e "INSIKA_DB=/data/harness.db" \
    -e "ADMIN_TOKEN=drill" \
    -e "LITESTREAM_REPLICA_URL=${REPLICA_URL}" \
    "${IMAGE}"
}

wait_up() {
  local port="$1" i
  for i in $(seq 1 60); do
    if curl -fsS "http://localhost:${port}/up" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "  /up never turned green" >&2
  docker logs "${CID}" >&2 || true
  return 1
}

port_of() { docker port "$1" 9292/tcp | head -1 | sed 's/.*://'; }

log "2/6 boot container A (Litestream ENABLED) → replicate"
CID="$(run_container a)"
PORT_A="$(port_of "${CID}")"
wait_up "${PORT_A}"
echo "  app up on :${PORT_A}; letting Litestream sync (5s)…"
sleep 5

log "3/6 stop A (SIGTERM → Litestream final sync)"
docker stop -t 15 "${CID}" >/dev/null
docker rm -f "${CID}" >/dev/null; CID=""
test -n "$(ls -A "${REPLICA}" 2>/dev/null)" || { echo "  FAIL: replica is empty" >&2; exit 1; }
echo "  replica populated: $(find "${REPLICA}" -type f | wc -l | tr -d ' ') files"

log "4/6 WIPE the data volume (simulate a lost box)"
rm -f "${DATA}"/harness.db "${DATA}"/harness.db-shm "${DATA}"/harness.db-wal
test ! -f "${DATA}/harness.db" || { echo "  FAIL: db not wiped" >&2; exit 1; }
echo "  ${DATA}/harness.db removed"

log "5/6 boot container B → entrypoint RESTORES from replica"
CID="$(run_container b)"
PORT_B="$(port_of "${CID}")"
wait_up "${PORT_B}"
docker logs "${CID}" 2>&1 | grep -i "restor" || true

log "6/6 assert marker survived the restore"
test -f "${DATA}/harness.db" || { echo "  FAIL: db not restored" >&2; exit 1; }
GOT="$(sqlite3 "${DATA}/harness.db" "SELECT tag FROM drill_marker LIMIT 1;")"
if [ "${GOT}" = "${MARKER}" ]; then
  printf '\n\033[1;32m[drill] PASS\033[0m — marker %s restored from replica; /up green on the new box.\n' "${MARKER}"
else
  printf '\n\033[1;31m[drill] FAIL\033[0m — expected %s, got "%s".\n' "${MARKER}" "${GOT}" >&2
  exit 1
fi
