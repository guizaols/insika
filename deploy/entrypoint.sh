#!/bin/sh
# Container entrypoint for the Insika engine.
#
# Litestream is OPT-IN. It stays entirely out of the boot path
# unless LITESTREAM_REPLICA_URL is set — a single-box ephemeral pilot pays zero
# cost and behaves exactly as before. When configured, Litestream:
#   1. restores insika.db from the replica on a fresh box (before the app opens
#      the DB), and
#   2. supervises the app process, replicating the SQLite WAL continuously to the
#      replica and doing a final sync on shutdown.
# Zero Ruby code change: the DB path is the same INSIKA_DB the app already uses.
set -e

# Resolve once and re-export as INSIKA_DB so litestream.yml (${INSIKA_DB}) and the app agree.
DB="${INSIKA_DB:-/data/insika.db}"
export INSIKA_DB="${DB}"

# One-shot adoption of a pre-rename volume: the image default moved from
# harness.db to insika.db, so a redeploy would otherwise boot on an EMPTY
# database with the real one still sitting on the disk. Rename it here — before
# anything opens it — taking the -wal/-shm siblings along, or a crash-time WAL
# holding committed transactions would be orphaned. Only when the target does
# not exist yet, so it can never clobber a live database, and a no-op from the
# second boot on. This is deploy baggage and belongs here, not in the engine:
# point INSIKA_DB at the old filename and none of it runs.
LEGACY_DB="$(dirname "${DB}")/harness.db"
if [ ! -f "${DB}" ] && [ -f "${LEGACY_DB}" ]; then
  echo "[entrypoint] adopting pre-rename database ${LEGACY_DB} -> ${DB}"
  for suffix in "" "-wal" "-shm"; do
    [ -f "${LEGACY_DB}${suffix}" ] && mv "${LEGACY_DB}${suffix}" "${DB}${suffix}"
  done
fi
# WEB_CONCURRENCY is a contract input, not a tuning knob: N workers share one
# SQLite store, but a session's live semantics (FIFO, steer, interrupt, pause,
# SSE watch) are per-worker. The default is 1 because those semantics are the
# product (queue modes need one actor per session); raise it only with
# sticky routing per session in front. What changing N means is written in
# docs/DEPLOY.md ("The process model") — that section is the single source of
# truth.
#
# Shutdown is a drain: each worker traps the stop signal, closes
# its turn intake and finishes in-flight turns within INSIKA_DRAIN_TIMEOUT
# (default 20s). Falcon's controller must wait AT LEAST that long before killing
# the workers — its default --graceful-stop is 1s — hence drain + 5 here. The
# platform must wait longer still: on Railway set
# RAILWAY_DEPLOYMENT_DRAINING_SECONDS >= drain + 15, since the router (INSIKA_WORKERS
# > 1) waits up to drain + 10 for the replies in flight (its default is 0: SIGKILL
# right after SIGTERM, which cancels the whole drain). See docs/DEPLOY.md.
DRAIN="${INSIKA_DRAIN_TIMEOUT:-20}"
APP_CMD="bundle exec falcon serve --bind http://0.0.0.0:${PORT:-9292} --count ${WEB_CONCURRENCY:-1} --graceful-stop $((DRAIN + 5))"

# INSIKA_WORKERS > 1 is the safe way to use more cores: N single-worker
# processes behind the session-sticky insika-router (deploy/workers.sh). It
# replaces WEB_CONCURRENCY, so both at once is refused.
if [ "${INSIKA_WORKERS:-1}" -gt 1 ]; then
  if [ "${WEB_CONCURRENCY:-1}" -gt 1 ]; then
    echo "[entrypoint] INSIKA_WORKERS and WEB_CONCURRENCY>1 are exclusive — set WEB_CONCURRENCY=1" >&2
    exit 1
  fi
  APP_CMD="bash /app/deploy/workers.sh"
fi

# Boot generation for the recovery task sweep: one id per
# container start, inherited by every Falcon worker. The first worker to claim
# it runs the sweep; the others (and any worker respawned mid-generation) skip,
# so a rebooting worker never "recovers" a sibling's live turn. See
# docs/DEPLOY.md "The process model".
export INSIKA_BOOT_ID="${INSIKA_BOOT_ID:-$(date +%s)-$$}"

# Open the store once, alone, before any worker: a file in an older table layout
# is rebuilt here (seconds on a large file) instead of under N workers racing for
# the lock at boot. A no-op on an up-to-date file.
#
# It also reads every config:* row once. A new container starts with an empty page
# cache, and at boot every worker reloads the config (skills, settings): scattered
# reads that, cold, held all workers ~45s after each Railway deploy. Reading the
# whole file in the background did not help (65 MB/s, 46s for 3 GB, competing with
# the workers); the config is ~25 MB, so it is read here, before the workers start.
prepare_db() {
  echo "[entrypoint] preparing ${DB}…"
  # INSIKA_CONFIG_DB: the config lives in its own small file — one sequential read
  # fills the cache with all of it.
  if [ -n "${INSIKA_CONFIG_DB}" ] && [ -f "${INSIKA_CONFIG_DB}" ]; then
    cat "${INSIKA_CONFIG_DB}" "${INSIKA_CONFIG_DB}-wal" > /dev/null 2>&1 || true
  fi
  bundle exec ruby -Ilib -rinsika -e '
    store = Insika::Wiring::Graph.raw_backend_from_env
    if store.is_a?(Insika::Stores::ScopeSplit)
      copied = store.adopt!
      puts "[entrypoint] config copied to #{ENV["INSIKA_CONFIG_DB"]}: #{copied} rows" if copied.positive?
    end
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    open_tasks = Insika::TaskStore.new(store: store).build_open_index!
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
    puts "[entrypoint] open-task index built: #{open_tasks} open tasks in #{ms}ms" if ms > 50
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows = store.scopes("config:").sum { |scope| store.entries(scope).size }
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
    puts "[entrypoint] config warmed: #{rows} rows in #{ms}ms"
    store.close
  '
}

# Postgres store: no SQLite file to prepare and nothing for Litestream to replicate —
# Postgres owns durability (its own backups / point-in-time recovery).
if [ -n "${INSIKA_DATABASE_URL}" ]; then
  [ -n "${LITESTREAM_REPLICA_URL}" ] && echo "[entrypoint] INSIKA_DATABASE_URL set — ignoring LITESTREAM_REPLICA_URL." >&2
  echo "[entrypoint] Postgres store — booting app directly."
  exec sh -c "${APP_CMD}"
fi

if [ -z "${LITESTREAM_REPLICA_URL}" ]; then
  echo "[entrypoint] Litestream disabled (LITESTREAM_REPLICA_URL unset) — booting app directly."
  prepare_db
  exec sh -c "${APP_CMD}"
fi

CONFIG="/app/deploy/litestream.yml"
# A separate config file replicates to its own path (LITESTREAM_CONFIG_REPLICA_URL).
if [ -n "${INSIKA_CONFIG_DB}" ]; then
  if [ -z "${LITESTREAM_CONFIG_REPLICA_URL}" ]; then
    echo "[entrypoint] INSIKA_CONFIG_DB needs LITESTREAM_CONFIG_REPLICA_URL when Litestream is on" >&2
    exit 1
  fi
  CONFIG="/tmp/litestream.yml"
  cat /app/deploy/litestream.yml > "${CONFIG}"
  cat >> "${CONFIG}" <<'YML'
  - path: ${INSIKA_CONFIG_DB}
    truncate-page-n: 0
    replica:
      url: ${LITESTREAM_CONFIG_REPLICA_URL}
      endpoint: ${LITESTREAM_ENDPOINT}
      region: ${LITESTREAM_REGION}
YML
fi
echo "[entrypoint] Litestream enabled — replica=${LITESTREAM_REPLICA_URL} db=${DB}"

# Fresh box: pull the last replicated snapshot before the app opens the DB.
# -if-replica-exists makes this a no-op (exit 0) when the replica is empty (very
# first deploy) so the app just starts on a blank DB. When the durable volume
# survived a redeploy the file is already present and this branch is skipped.
if [ ! -f "${DB}" ]; then
  echo "[entrypoint] ${DB} absent — attempting restore from replica…"
  litestream restore -if-replica-exists -config "${CONFIG}" "${DB}"
else
  echo "[entrypoint] ${DB} present — skipping restore (volume survived)."
fi
if [ -n "${INSIKA_CONFIG_DB}" ] && [ ! -f "${INSIKA_CONFIG_DB}" ]; then
  echo "[entrypoint] ${INSIKA_CONFIG_DB} absent — attempting restore from replica…"
  litestream restore -if-replica-exists -config "${CONFIG}" "${INSIKA_CONFIG_DB}"
fi

prepare_db

# Supervise: Litestream replicates the WAL and forwards signals to the child.
# When the app exits, Litestream final-syncs and exits too (Railway restarts the
# container per railway.json restart policy).
exec litestream replicate -config "${CONFIG}" -exec "${APP_CMD}"
