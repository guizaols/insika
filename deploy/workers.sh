#!/bin/bash
# N engine workers behind insika-router, inside one container (docs/ROUTER.md,
# "Deploy shape 1 — Railway"). Started by entrypoint.sh when INSIKA_WORKERS > 1.
#
# Each worker is its own Falcon process (--count 1) on a local port, so each
# holds its own SessionActors; the router, on the port Railway forwards, sends a
# session's requests to the same worker every time. That is what keeps FIFO,
# steer and the SSE watch correct at N > 1 — never `--count N` on one port.
#
# The router only binds once every worker accepts connections, so Railway's
# /up healthcheck (answered by the router itself) cannot pass on a half-booted
# container. If any child dies, the others are stopped and the script exits
# non-zero, so the platform restarts the whole container.
set -u

N="${INSIKA_WORKERS}"
DRAIN="${INSIKA_DRAIN_TIMEOUT:-20}"
BASE_PORT="${INSIKA_WORKER_BASE_PORT:-9300}"
pids=()
backends=""

stop_all() {
  kill -TERM "${pids[@]}" 2>/dev/null
  wait
}
trap 'stop_all; exit 0' TERM INT

for ((i = 0; i < N; i++)); do
  port=$((BASE_PORT + i))
  bundle exec falcon serve --bind "http://127.0.0.1:${port}" --count 1 --graceful-stop $((DRAIN + 5)) &
  pids+=($!)
  backends="${backends:+${backends},}http://127.0.0.1:${port}"
done

# Boot runs recovery before the listen, so a port that accepts means a ready worker.
for ((i = 0; i < N; i++)); do
  port=$((BASE_PORT + i))
  until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    kill -0 "${pids[$i]}" 2>/dev/null || { echo "[workers] worker on ${port} died during boot"; stop_all; exit 1; }
    sleep 0.5
  done
done
echo "[workers] ${N} workers ready: ${backends}"

# A turn can stream for up to turn_timeout (1200s on the stores); the router's
# default 10s backend timeout would cut a slow answer mid-flight.
INSIKA_ROUTER_HOST=0.0.0.0 \
INSIKA_ROUTER_PORT="${PORT:-9292}" \
INSIKA_ROUTER_BACKENDS="${backends}" \
INSIKA_ROUTER_BACKEND_TIMEOUT="${INSIKA_ROUTER_BACKEND_TIMEOUT:-1300}" \
  bundle exec insika-router &
pids+=($!)

# Poll instead of `wait -n` so the script also runs on bash 3 (macOS).
while :; do
  for pid in "${pids[@]}"; do
    kill -0 "${pid}" 2>/dev/null || break 2
  done
  sleep 1
done
echo "[workers] a child exited — stopping the rest"
stop_all
exit 1
