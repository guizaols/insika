---
title: Deploy
parent: Ship it
nav_order: 3
permalink: /deploy/
---

# Deploy

How to run the engine in a container (Railway today, Kubernetes later) and how to
measure performance and load.

## Image (Docker)

The `Dockerfile` (multi-stage, YJIT on) serves `config.ru` under Falcon. The Studio
ships with its `dist/` built and vendored — **no Node in the build**. The backend
is durable SQLite (WAL) at `INSIKA_DB`; mount a volume and point it inside.

```bash
docker build -t insika .
docker run -p 9292:9292 -v insika-data:/data \
  -e DEEPSEEK_API_KEY=sk-... \
  -e OPENCLAW_GATEWAY_TOKEN=change-me \
  insika
curl localhost:9292/up      # {"status":"ok"}
```

## Environment variables

| Env | Default | Effect |
|-----|---------|--------|
| `INSIKA_DB` | `/data/insika.db` (in the image) | durable SQLite path (**mount a volume!**) |
| `PORT` | `9292` | HTTP bind port |
| `WEB_CONCURRENCY` | `2` | number of Falcon worker processes |
| `OPENCLAW_GATEWAY_TOKEN` | falls back to `ADMIN_TOKEN` | Bearer for `/v1/responses` and `/v1/agents` (the API contract) |
| `ADMIN_TOKEN` | `local-demo` | login token for `/studio` (**change in production**) |
| `DEEPSEEK_API_KEY` | — | provider key. **Without it the engine still boots** (`/up` green), but turns fail until it is configured (env or Studio → LLM providers) — cloud resilience |
| `DEEPSEEK_MODEL` | `deepseek-chat` | model |
| `CONSUMER_INTERNAL_URL` | — | base URL for data-tools calling back a consumer's internal API (see below) |
| `INSIKA_EGRESS_HOSTS` | — | outbound host allowlist (SSRF guard) |
| `INSIKA_EGRESS_ALLOW_HTTP` / `_ALLOW_PRIVATE` | off | for `http`/loopback callbacks only (**never in cloud**) |
| `INSIKA_RELAY_TOKEN` | — | **mounts the relay channel** at `POST /channels/relay/events`, and is the Bearer it requires. Empty = the route does not exist (`404`). See [Channels](CHANNELS.md) |
| `INSIKA_RELAY_DELIVER_URL` | — | your callback; the engine POSTs each reply there. Goes through the egress guard |
| `INSIKA_RELAY_DELIVER_TOKEN` | — | Bearer the engine sends **to** your callback (optional) |
| `LITESTREAM_REPLICA_URL` | — | **enables Litestream** (backup/DR). Empty = disabled (default). See below |
| `LITESTREAM_ENDPOINT` | — | S3-compatible endpoint (R2/MinIO). Empty = AWS S3 |
| `LITESTREAM_REGION` | — | bucket region (AWS: `us-east-1`; R2: `auto`) |
| `LITESTREAM_ACCESS_KEY_ID` / `LITESTREAM_SECRET_ACCESS_KEY` | — | bucket credentials (read natively by Litestream) |

> **Renamed from `HARNESS_*` → `INSIKA_*`.** Every engine variable now uses the
> `INSIKA_` prefix. The old `HARNESS_*` names are still honored as deprecated aliases
> — set either one and the engine reads it, logging a one-line deprecation notice at
> boot (`insika doctor` reports it too). Migrate at your convenience; the legacy names
> will be dropped in a future release.

> **The database filename changed too** — the image now defaults to
> `INSIKA_DB=/data/insika.db` (it was `/data/harness.db`). **Existing volumes are
> adopted automatically:** the container entrypoint renames the old file — with its
> `-wal`/`-shm` siblings, before anything opens it — when the configured path does
> not exist yet. Nothing to run by hand, no data lost, and a no-op from the second
> boot on. To keep the old filename instead, point `INSIKA_DB` at it: the variable
> is the knob, the image only picks a default. (The adoption lives in
> `deploy/entrypoint.sh`, not in the engine — it is deploy baggage, not a runtime
> behavior.)

### Tokens & rotation (keep the two separate!)

There are **two** secrets with distinct purposes — in production use **different**
values (the API token falling back to `ADMIN_TOKEN` is a dev convenience only):

- **`ADMIN_TOKEN`** — the `/studio` login (cookie auth). This is the **operator**
  surface (just you). Rotating it is **safe and independent**: change it, redeploy,
  log in with the new value. It does not affect any API consumer.
- **`OPENCLAW_GATEWAY_TOKEN`** — the Bearer for `/v1/responses` and `/v1/agents`.
  This is the **contract with your API consumers**. Rotating it means **changing
  both sides together** (or the integration breaks): update the runtime var **and**
  each consumer's token in the same step.

Generate a strong token: `ruby -rsecurerandom -e 'puts SecureRandom.hex(24)'`.

### Strict config and `insika doctor`

Config discipline that **rejects unknown keys — no silent schema tolerance**. Two
parts:

**1. Boot gate.** On boot, the engine validates the environment against a schema of
known keys (`Insika::EnvSchema`): a wrong type (`INSIKA_PORT=abc`) or an
**unknown key in the `INSIKA_` namespace** (a typo like `INSIKA_EGRES_ALLOW_HTTP`
the runtime would silently ignore). By **default it only warns** and boots anyway
(*last-known-good* — a rotated key or a typo never takes the whole service down).
To **refuse boot** on any finding, set `INSIKA_CONFIG_STRICT=1`. Unknown-key
detection is scoped to the `INSIKA_` prefix; the shared `OPENCLAW_`, `LITESTREAM_`,
and `OTEL_` namespaces are never flagged.

**2. `bin/insika doctor` — on-demand diagnostics.** Reads the **same** durable
backend the server uses (`INSIKA_DB`) without booting the whole app (no provider,
no seed) — safe to run against a production volume:

```bash
insika doctor            # colored report; exits != 0 on any error
insika doctor --json     # machine-readable (CI / monitoring)
insika doctor --fix      # applies the safe autofixes and re-diagnoses
insika env               # lists known keys + current values (secrets masked)
```

Checks: env (the schema above), settings schema version (a pending migration →
`--fix` applies it), a missing platform `default_model` (`--fix` seeds it from
`DEEPSEEK_MODEL`), durable vs ephemeral backend, LLM provider configured,
`ADMIN_TOKEN` set, data-tool definitions still valid, and **prompt files that hold
text rather than a serialized object** (a file whose content is a stringified Hash
serves a mangled prompt on every turn while looking perfectly healthy — present,
non-empty, and the agent still answers). Settings-schema migrations are **explicit**
— no Studio save silently reinterprets old-shape data.

### Data-tool callbacks to a backend — via a tunnel

Data-tools call back a consumer's internal HTTP API. With the engine **in the
cloud** and your backend **on your machine** (`:3000`), expose it over a public
`https` tunnel and point the engine at it:

```bash
# in the tool/manifest: base_url = {{env.CONSUMER_INTERNAL_URL}}
CONSUMER_INTERNAL_URL=https://your-tunnel.example.dev
INSIKA_EGRESS_HOSTS=your-tunnel.example.dev
```

Because the tunnel is **public `https`**, the strict egress guard (the default)
**already allows it** — you do **not** need `ALLOW_HTTP`/`ALLOW_PRIVATE` (those are
only for a fully-local loop). Restricting `INSIKA_EGRESS_HOSTS` to the tunnel host
is the secure posture. See [Security](SECURITY.md#egress-the-ssrf-boundary).

## Railway

`railway.json` already configures the Dockerfile builder, `startCommand`, the `/up`
healthcheck, and a restart policy.

1. Create the project/service from this repo (builder = Dockerfile).
2. **Volume**: mount it at `/data` (the default `INSIKA_DB` points there) —
   without a volume, SQLite is ephemeral and recovery resumes nothing after a
   redeploy.
3. **Vars**: `DEEPSEEK_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`, `CONSUMER_INTERNAL_URL`,
   `INSIKA_EGRESS_HOSTS` (and `WEB_CONCURRENCY` to match your plan/CPU).
4. The healthcheck hits `/up`.
5. Point your consumer at the service's public URL, with a matching API token
   (see [RUNNING-LOCAL.md](RUNNING-LOCAL.md)).

## Backup / DR — Litestream (opt-in, configurable)

A single volume is the **one point of total loss** between a pilot and production
(disk corruption/loss = goodbye conversations + config). Litestream does
**continuous replication** of `insika.db` (its WAL) to an S3/R2 bucket, without
changing databases and **without a line of Ruby**.

It is **off by default** and turns on by env — a single-box ephemeral deploy pays
nothing; a durable deploy enables it by pointing at a bucket. The trigger is one
variable, `LITESTREAM_REPLICA_URL`:

- **empty (default):** the entrypoint `exec`s Falcon directly. The Litestream binary
  is never invoked — behavior identical to not having it.
- **set:** on a fresh box the entrypoint **restores** `insika.db` from the replica
  *before* the app opens it (`litestream restore -if-replica-exists`; a no-op if the
  bucket is still empty), then **supervises** the app (`litestream replicate -exec`),
  replicating the WAL continuously and doing a final sync on shutdown (Railway's
  SIGTERM).

### Enable in production (Railway)

Add the vars (keep the volume at `/data`):

```bash
# AWS S3
LITESTREAM_REPLICA_URL=s3://my-bucket/insika
LITESTREAM_REGION=us-east-1
LITESTREAM_ACCESS_KEY_ID=AKIA...
LITESTREAM_SECRET_ACCESS_KEY=...

# Cloudflare R2 (S3-compatible): same, + endpoint and region=auto
LITESTREAM_REPLICA_URL=s3://my-bucket/insika
LITESTREAM_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
LITESTREAM_REGION=auto
LITESTREAM_ACCESS_KEY_ID=...
LITESTREAM_SECRET_ACCESS_KEY=...
```

Credentials are read natively by Litestream (they are not in `deploy/litestream.yml`,
which only references URL/endpoint/region via `${VAR}`).

### Restore drill (the real "done" — an untested backup does not count)

The pilot→production gap only closes once a restore has been **exercised**. Two ways:

**1. Local, automated (proves the mechanism, zero credentials):** uses the real
image + a `file://` replica; boots → replicates → deletes the volume → boots a new
box → restores → confirms the marker row survived and `/up` is green.

```bash
scripts/litestream-restore-drill.sh      # needs docker, sqlite3, curl
# → [drill] PASS — marker … restored from replica; /up green on the new box.
```

**2. Production (the drill that counts for go-live):** against the real bucket.

```bash
# a. with the service live and replicating, generate some config/conversation and
#    confirm the replica has generations:
litestream snapshots -config deploy/litestream.yml "$INSIKA_DB"

# b. boot a NEW box (empty volume) with the same LITESTREAM_* vars → the entrypoint
#    restores on boot. Verify manually in /studio that conversations and config came
#    back. Manual restore alternative:
litestream restore -config deploy/litestream.yml -o /tmp/restored.db "$INSIKA_DB"
```

## Kubernetes (evolution)

SQLite does not share one file across nodes. Paths forward: a StatefulSet + a PVC
per pod + **sticky-by-agent** routing (shard by tenant), or **LiteFS**, or an
optional **Postgres** adapter. **Litestream** (above) for backup/DR from day one —
orthogonal to topology.

---

## Measuring performance / load

### 1. SQLite write ceiling (no provider) — `bench_store.rb`

Isolates "can SQLite take multi-process writes?" from LLM noise: N processes
hammering writes on the **same** file (WAL + busy_timeout — the real config).

```bash
bundle exec ruby scripts/bench_store.rb 1,2,4,8 3000
```

**Measured (mid-2026, laptop, ~481B payload):**

| procs | writes/s (aggregate) | p50 | p95 | max | locked |
|------:|--------------------:|----:|----:|----:|-------:|
| 1 | ~29.6k | 0.02ms | 0.04ms | 2.4ms | **0** |
| 2 | ~29.9k | 0.02ms | 0.04ms | 59ms | **0** |
| 4 | ~23.7k | 0.02ms | 0.05ms | 336ms | **0** |
| 8 | ~28.4k | 0.03ms | 0.05ms | 539ms | **0** |

**Reading:** aggregate throughput stays ~25–30k writes/s regardless of process
count (the WAL's one-writer-at-a-time ceiling), with **zero "database is locked"**
(the `busy_timeout` absorbs contention into tail latency, not errors), and a
microscopic p95. A real turn is **provider-bound (seconds)** and does a handful of
writes → the workload sits ~100× under the ceiling. **Empirically, SQLite is not
the bottleneck on a single box.**

### 2. End-to-end load (with provider) — `loadtest.rb`

Hits `POST /v1/responses` (SSE), the production path. Measures TTFB, total, tokens,
cache hits, P50/P95, error rate. Runs against local or a remote deployment. See
[LOADTEST.md](LOADTEST.md).

```bash
INSIKA_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=xxx \
  bundle exec ruby scripts/loadtest.rb --agents assistant --concurrency 16 --iterations 3
```

### 3. Baseline vs multi-worker on one box — `loadtest-local.sh`

Boots Falcon with 1 worker, then N, over the **same** SQLite, and counts "database
is locked" in the logs.

```bash
DEEPSEEK_API_KEY=sk-... ./scripts/loadtest-local.sh 4 24
```

## See also

- [RUNNING-LOCAL.md](RUNNING-LOCAL.md) — run the engine locally, single-process.
- [Security](SECURITY.md) — tokens, egress, strict config.
- [BENCHMARK.md](BENCHMARK.md) — the neutral, key-free engine benchmark.
- [OBSERVABILITY.md](OBSERVABILITY.md) — OpenTelemetry traces + metrics (opt-in).
