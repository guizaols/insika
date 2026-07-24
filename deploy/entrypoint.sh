#!/bin/sh
# Container entrypoint for the harness engine.
#
# Litestream is OPT-IN (FOLLOWUP §12 G1). It stays entirely out of the boot path
# unless LITESTREAM_REPLICA_URL is set — a single-box ephemeral pilot pays zero
# cost and behaves exactly as before. When configured, Litestream:
#   1. restores harness.db from the replica on a fresh box (before the app opens
#      the DB), and
#   2. supervises the app process, replicating the SQLite WAL continuously to the
#      replica and doing a final sync on shutdown.
# Zero Ruby code change: the DB path is the same INSIKA_DB the app already uses.
set -e

# INSIKA_DB is the current name; HARNESS_DB is honored as a deprecated alias. Resolve
# once and re-export as INSIKA_DB so litestream.yml (${INSIKA_DB}) and the app agree.
DB="${INSIKA_DB:-${HARNESS_DB:-/data/harness.db}}"
export INSIKA_DB="${DB}"
APP_CMD="bundle exec falcon serve --bind http://0.0.0.0:${PORT:-9292} --count ${WEB_CONCURRENCY:-2}"

if [ -z "${LITESTREAM_REPLICA_URL}" ]; then
  echo "[entrypoint] Litestream disabled (LITESTREAM_REPLICA_URL unset) — booting app directly."
  exec sh -c "${APP_CMD}"
fi

CONFIG="/app/deploy/litestream.yml"
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

# Supervise: Litestream replicates the WAL and forwards signals to the child.
# When the app exits, Litestream final-syncs and exits too (Railway restarts the
# container per railway.json restart policy).
exec litestream replicate -config "${CONFIG}" -exec "${APP_CMD}"
