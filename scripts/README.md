# scripts/

Developer and operator scripts. Not part of the runtime — utilities for
provisioning, running locally, migrating, and load-testing.

## Load & performance testing

See [../docs/BENCHMARK.md](../docs/BENCHMARK.md) for the neutral engine benchmark
and [../docs/LOADTEST.md](../docs/LOADTEST.md) for end-to-end load testing.

- **`bench.rb`** — neutral, reproducible, **provider-free** benchmark of the engine
  overhead per turn (context build, policy, tool round-trip, streaming, persistence)
  across synthetic scenarios (greeting / tool_call / multi_turn). No API key. Reports
  p50/p95 latency, throughput, and per-token pipeline overhead. `--help` / `--json`.
- **`loadtest.rb`** — end-to-end load test hitting `POST /v1/responses` (SSE):
  TTFB, total, tokens, cache hit, P50/P95, error rate. Ruby port of OpenClaw's
  `loadtest-gateway.mjs`. `--help` / `--dry-run` supported.
- **`loadtest-local.sh`** — boots Falcon single-proc (baseline) vs N workers over
  one shared SQLite (WAL) and counts `database is locked`.
- **`bench_store.rb`** — micro-bench of the SQLite write ceiling under N processes
  (no provider needed); reports writes/s, p50/p95/max, `locked`.

## Provisioning & running locally

- **`import_pack.rb`** — provisions a pack (agent.config.json + skills + tools)
  into a **running** harness via `POST /v1/agents`. Runs as a client (no provider
  key needed); the server reloads the tool overlay and skill catalog in place.
- **`serve_real.rb`** — boots the real single-process HTTP server (`/admin`,
  `/v1/*`) against the seeded Bia deployment; open `/admin/chat` and converse with
  real tools/skills/memory.
- **`run_real.rb`** — real multi-turn conversation with Bia (DeepSeek) from the
  CLI, serialized by the SessionActor; streams events, tools, skills and returns.
