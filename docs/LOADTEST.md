# LOADTEST — Harness

How to load-test the harness, how to compare it **apples-to-apples against the
OpenClaw gateway**, and how to read the numbers. This is the "how to compare"
companion to [FOLLOWUP.md](FOLLOWUP.md) §1.3 (does SQLite hold up production?) and
§1.4 (loadtest parity with OpenClaw). For deploy/env details see
[DEPLOY.md](DEPLOY.md).

The whole point: the harness exposes `POST /v1/responses` as an **SSE drop-in** of
the OpenClaw gateway. Same contract → the same load tools work against either side,
so you can measure the engine you are about to ship against the gateway it replaces.

There are three scripts, each answering a different question:

| Script | Question it answers | Needs a provider? |
|--------|---------------------|-------------------|
| `scripts/bench_store.rb` | Does SQLite (WAL) hold up N processes writing the same file? | No |
| `scripts/loadtest.rb` | End-to-end: TTFB/total/tokens/cache/error against `/v1/responses` | Yes |
| `scripts/loadtest-local.sh` | Single-proc baseline vs N-worker multi-proc on one box | Yes |

All three take `--help` / `-h`.

---

## 1. `bench_store.rb` — SQLite write ceiling (no provider)

Isolates "does SQLite survive multi-process?" from LLM-provider noise. N processes
hammer writes against the **same file** using the harness's real production config
(WAL + `busy_timeout` + `BEGIN IMMEDIATE` + in-process semaphore). It uses a fresh
temp db per round, so it never touches your `HARNESS_DB`.

```bash
bundle exec ruby scripts/bench_store.rb [PROCS_CSV] [WRITES_PER_PROC]
# defaults: 1,2,4,8 procs, 2000 writes each
bundle exec ruby scripts/bench_store.rb 1,2,4,8 3000
```

Output columns: `procs | wall(s) | writes/s | p50(ms) | p95(ms) | max(ms) | locked`.

**What to look for:** aggregate `writes/s` stays roughly flat as procs grow (the
WAL "1 writer at a time" ceiling), and `locked` (i.e. `database is locked`) is **0**
— the `busy_timeout` turns contention into tail latency (`max`), not errors. A real
turn is provider-bound (seconds) and does only a handful of writes, so the workload
sits ~100× below this ceiling. See DEPLOY.md for the measured numbers.

---

## 2. `loadtest.rb` — end-to-end against `/v1/responses` (with provider)

Hits `POST /v1/responses` (SSE) directly — the production path
(consumer-app/WhatsApp → engine). Standard library only. Fires `agents × concurrency ×
iterations` turns in waves of `concurrency`, and per turn records TTFB (time to
first SSE byte), total time, and the `usage` block (tokens + cache hit) of the last
frame that carries it.

```bash
HARNESS_URL=http://localhost:9292 \
OPENCLAW_GATEWAY_TOKEN=xxx \
bundle exec ruby scripts/loadtest.rb \
  --agents bia,agent-store-acme --concurrency 16 --iterations 3 \
  --message "hi, how are you?"
```

Runs against a local server **or** a remote one (e.g. Railway) — just point
`HARNESS_URL` at it.

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--agents a,b,c` | `bia` | comma-separated agent ids (mapped to `model: openclaw:<agent>`) |
| `--concurrency N` | `8` | concurrent turns per wave |
| `--iterations N` | `1` | number of waves per agent |
| `--message TEXT` | greeting | user message sent every turn |
| `--timeout SECONDS` | `120` | per-request read timeout |
| `--ports 9292,9293` | — | round-robin across local processes (see §4) |
| `--same-user` | off | boolean toggle — reuse the same `user` per agent to measure the **hot-conversation cache** (legacy `--same-user 1` / `--same-user 0` still work) |
| `--dry-run` | — | print the plan + one sample request (masked token) and exit; **sends no traffic** |
| `--help` | — | show usage and exit |

### Environment

| Env | Default | Meaning |
|-----|---------|---------|
| `HARNESS_URL` | `http://localhost:9292` | base URL of the engine |
| `OPENCLAW_GATEWAY_TOKEN` | falls back to `ADMIN_TOKEN`, then `local-demo` | Bearer for `/v1/responses` |
| `DEEPSEEK_API_KEY` | — | must be configured **on the server** for real turns (not read by the client) |

Use `--dry-run` to sanity-check your flags/URL/token before firing real traffic
(and to confirm the request body without needing a running server):

```bash
HARNESS_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=xxx \
  bundle exec ruby scripts/loadtest.rb --agents bia --concurrency 16 --dry-run
```

### `--same-user` and the cache

By default each turn uses a distinct `user` (`loadtest-<agent>-<idx>`), so every
turn is a cold conversation. With `--same-user` all turns for an agent share one
`user`, exercising the warm-conversation path — watch the **mean cache hit** rise
and TTFB drop. Run both to bracket cold vs hot behaviour.

---

## 3. `loadtest-local.sh` — baseline vs multi-worker on one box (§1.3 proof)

Boots Falcon with `--count 1` (single-process baseline), runs the sweep, then boots
`--count N` (multi-process) over the **same** SQLite file (WAL), runs the sweep
again, and counts `database is locked` in each Falcon log. Since the provider is
identical across both runs, if multi-proc recovers throughput the ceiling was
CPU/event-loop (not the provider), and a `locked` count of **0** proves the WAL +
`busy_timeout` config absorbs cross-process write contention.

```bash
DEEPSEEK_API_KEY=sk-... ./scripts/loadtest-local.sh [WORKERS] [CONCURRENCY]
# defaults: 4 workers, 16 concurrency
./scripts/loadtest-local.sh 4 24
```

| Env | Default | Meaning |
|-----|---------|---------|
| `DEEPSEEK_API_KEY` | — (required) | real turns hit the provider; also auto-sourced from `.env.local` |
| `OPENCLAW_GATEWAY_TOKEN` | falls back to `ADMIN_TOKEN`, then `local-demo` | Bearer for the sweep |
| `PORT` | `9299` | bind port for the local Falcon |
| `AGENT` | `bia` | agent id to load |

The final block prints the lock counts; the expected reading is `0` for both:

```
=== 'database is locked' (expected 0 — WAL + busy_timeout) ===
  baseline (1):        0
  multi (4):           0
```

---

## 4. Apples-to-apples: harness vs the OpenClaw gateway

Two ways to compare, both valid because the SSE contract is identical.

### 4a. Ruby native (`loadtest.rb`) against both

Run the same `loadtest.rb` invocation twice — once with `HARNESS_URL` pointing at
the harness, once at the gateway (its `/v1/responses` speaks the same protocol).
Keep `--agents`, `--concurrency`, `--iterations` and `--message` identical, and use
matching agents on both sides. Compare the printed TTFB/total/cache/error lines.

### 4b. Reuse OpenClaw's `loadtest-gateway.mjs` unmodified

`loadtest.rb` is the Ruby port of OpenClaw's `loadtest-gateway.mjs`. You do **not**
need to change that script to point it at the harness — because the harness is a
drop-in for the gateway, you only change **where it points**:

```bash
# In the OpenClaw checkout, run its gateway loadtest against the HARNESS:
OPENCLAW_GATEWAY_URL=http://localhost:9292 \
OPENCLAW_GATEWAY_TOKEN=<same bearer the harness accepts> \
node scripts/loadtest-gateway.mjs --agents bia --concurrency 16 --iterations 3
```

Then run the exact same command with `OPENCLAW_GATEWAY_URL` pointing at the real
gateway, and diff the two reports. This is the shadow comparison the pilot needs.

**What the operator must have in hand** (this repo does not vendor OpenClaw):

- The OpenClaw checkout containing `scripts/loadtest-gateway.mjs` and Node installed.
- A **bearer token accepted by both** sides. For the harness that is
  `OPENCLAW_GATEWAY_TOKEN` (see DEPLOY.md); point the gateway run at its own token.
- **The same agent id provisioned on both** sides (e.g. `bia`) so `model:
  openclaw:<agent>` resolves on each. On the harness, provision via
  `scripts/import_pack.rb`.
- The **same provider** (or an equivalent-latency one) behind each, otherwise you
  are comparing providers, not engines.
- Both endpoints reachable from where you run the client, warmed up (hit `/up` on
  the harness first), and ideally driven from the same machine to remove network
  skew.

Keep every knob identical between the two runs — the only variable should be which
engine is behind `/v1/responses`.

---

## 5. Reading the metrics

- **TTFB** (time to first SSE byte) — how fast the user starts seeing a response.
  Dominated by provider latency + the harness's per-turn setup (context build,
  policy, first model call). This is the number that most shapes perceived latency.
- **total** — full turn wall time including the whole tool-loop and streamed
  output. `total − TTFB` is roughly the streaming/tool-loop tail.
- **P50 vs P95** — P50 is the typical turn; **P95 is the tail you actually feel**
  under load. A P50 that stays flat while P95 balloons as concurrency rises means
  you are queueing (CPU/event-loop or writer contention) — that is the signal to
  add workers (§3) or check `bench_store.rb`.
- **mean tokens** — average `total_tokens`/`output_tokens` per turn; sanity-checks
  that turns did real work and lets you compare cost between runs/engines.
- **mean cache hit** — average cached prompt tokens; should rise sharply with
  `--same-user 1`. A high hit rate is why warm conversations are cheaper and faster.
- **error rate** (`turns ok: X/Y (errors: N)`) — non-2xx, timeouts, or connection
  failures. Anything above ~0 under moderate load is a red flag; inspect server
  logs. Note `loadtest.rb` errors are transport/HTTP-level; `database is locked`
  specifically is counted by `loadtest-local.sh` from the Falcon logs, not here.
- **throughput** (`turns/s`) — completed turns per wall second; the headline
  capacity number for a given concurrency.

---

## 6. Checklist — what to measure before choosing a topology

Ties directly to FOLLOWUP §1.3 (SQLite topology) and §1.4 (loadtest parity). Work
top-down and **measure before assuming** — avoid premature topology optimization.

| # | Measure | Tool | Decision it informs |
|---|---------|------|---------------------|
| 1 | SQLite write ceiling & `locked` count under N procs | `bench_store.rb` | Is SQLite a bottleneck at all on one box? (Expected: no.) |
| 2 | Single-proc baseline TTFB/total/P95/throughput | `loadtest.rb` (or `loadtest-local.sh` count 1) | The reference point for everything else. |
| 3 | Multi-proc on one box: does throughput scale, `locked` = 0? | `loadtest-local.sh` | Do more Falcon workers help, and does the shared WAL hold? Sets `WEB_CONCURRENCY`. |
| 4 | Harness vs gateway, identical knobs | §4 (either method) | Is the harness at parity with the engine it replaces before cut-over? |
| 5 | Cold vs hot conversation (cache) | `loadtest.rb` with/without `--same-user 1` | Expected steady-state cost/latency once conversations warm up. |
| 6 | Remote (Railway) vs local | `loadtest.rb` with `HARNESS_URL` remote | Network/deploy overhead of the real environment. |

**Reaching for horizontal scale is only justified after 1–3 show the single box is
the limit.** If it is, FOLLOWUP §1.3 lays out the paths: sharding-by-tenant +
sticky routing (recommended), LiteFS, or an optional Postgres adapter — plus
Litestream for backup/DR regardless of topology. Do not skip straight to Postgres:
the numbers usually show SQLite on one big box is not the bottleneck.
