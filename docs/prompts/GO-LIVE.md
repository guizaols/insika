---
title: Prompt — go live
parent: Reference
nav_order: 5
permalink: /go-live/
layout: default
render_with_liquid: false
---

# Take this agent to production

> **You are a coding agent** (Claude Code, Codex, Cursor, …) reading this because a
> developer pasted a prompt pointing here — something like *"deploy this"* or *"take
> it to production"*. Treat this file as a **skill**: follow the steps in order and
> apply the RULES literally. Production is where shortcuts become incidents.

Your job: get **one working local setup** running as **one production instance**,
verified end to end. The authoritative reference is
[`docs/DEPLOY.md`](../DEPLOY.md) (served at `GET /docs/deploy.md`); this file is the
ordered path through it.

## Step 0 — Gather context (silently)

- **Repo or gem?** The reference deployment is a checkout of the insika repo
  (`Dockerfile` + `config.ru` + `railway.json` already in it). An adopter's own app
  consumes the gem instead — then the developer's repo needs its own image; the env
  contract below is identical.
- **Which platform?** Railway is the documented path. Any Docker host works; the
  Kubernetes caveats are in [`docs/DEPLOY.md`](../DEPLOY.md) § Kubernetes.
- **Does it work locally?** One green `reply()` or `serve` turn first. Do not debug an
  agent and a deployment at the same time.
- Read [`docs/DEPLOY.md`](../DEPLOY.md) and
  [`docs/SECURITY.md`](../SECURITY.md) before writing anything.

## Step 1 — Mint the two secrets (RULES, not taste)

Two tokens, **two different values** — the fallback of one onto the other is a dev
convenience only:

| Token | Gates | Rotating it |
|---|---|---|
| `ADMIN_TOKEN` | `/studio` login (the operator — just you) | safe, independent |
| `INSIKA_GATEWAY_TOKEN` | Bearer for `/v1/responses` + `/v1/agents` (your API consumers) | both sides together, same step |

Generate each: `ruby -rsecurerandom -e 'puts SecureRandom.hex(24)'`. Set them as
platform env vars. **Never** write either into a file, a commit, or your own output.

## Step 2 — The non-negotiable env

- **`INSIKA_DB` on a mounted volume** (the image defaults to `/data/insika.db` —
  mount a volume at `/data`). No volume = SQLite is ephemeral and recovery resumes
  nothing after a redeploy.
- **`WEB_CONCURRENCY` stays `1`.** It is a contract input, not a throughput knob:
  N>1 without session-sticky routing in front is a guaranteed cross-session reply
  leak, and `insika doctor` errors on it on Railway. The fix, when throughput is
  actually needed, is [`insika-router`](../ROUTER.md) in front — not a bigger number.
- **Provider key** (`DEEPSEEK_API_KEY` for the demo provider) — without it the engine
  still boots (`/up` green) but every turn fails until it is configured.
- **`INSIKA_EGRESS_HOSTS`** = exactly the hosts your data-tools call. A backend on the
  developer's machine gets a public **https tunnel** + its host in this list — never
  `INSIKA_EGRESS_ALLOW_HTTP`/`_ALLOW_PRIVATE` in cloud.
- On Railway also **`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30`**: the platform default
  is 0 — SIGKILL right after SIGTERM — which cancels the graceful drain entirely.

## Step 3 — Deploy

Railway (repo path — `railway.json` already sets builder, start command, `/up`
healthcheck, restart policy):

1. Create the project/service from the repo (builder = Dockerfile).
2. Mount the volume at `/data`.
3. Set the vars from Steps 1–2.
4. Deploy; the healthcheck must go green on `/up`.

Any Docker host, same contract:

```bash
docker build -t insika .
docker run -p 9292:9292 -v insika-data:/data \
  -e DEEPSEEK_API_KEY=... -e ADMIN_TOKEN=... -e INSIKA_GATEWAY_TOKEN=... \
  insika
```

## Step 4 — Prove it with ONE real turn

In order, each with evidence:

1. `curl https://<host>/up` → `{"status":"ok"}`.
2. `bin/insika doctor` against the deployed volume (or via the platform's shell) —
   relay its findings verbatim; fix errors before continuing.
3. One authenticated turn:

```bash
curl -N https://<host>/v1/responses \
  -H "Authorization: Bearer $INSIKA_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"<agent-id>","user":"go-live-check","input":"hello"}'
```

The reply must be real model output. 401 → token mismatch (Step 1); a provider error
→ key/model id (Step 2); anything else → stop and diagnose with
[`docs/prompts/DIAGNOSE-TURN.md`](DIAGNOSE-TURN.md) before touching config.

4. Log in to `/studio` with the new `ADMIN_TOKEN` and find the go-live-check session.

## Step 5 — Close the total-loss hole (Litestream)

A single volume is the one point of total loss. Enable continuous replication by env
(off by default, zero code): set `LITESTREAM_REPLICA_URL` + credentials per
[`docs/DEPLOY.md`](../DEPLOY.md) § Backup / DR. Then **run the restore drill** — an
untested backup does not count:

```bash
scripts/litestream-restore-drill.sh   # local proof of the mechanism, or the
                                      # production drill in DEPLOY.md § Restore drill
```

If the developer declines Litestream, record that as an explicit accepted risk in
your report — do not silently skip it.

## Step 6 — Self-check

- [ ] `/up` green, `doctor` clean, one real authenticated turn with model output.
- [ ] Two distinct tokens, both only in platform env; nothing secret in git or logs.
- [ ] Volume mounted; `WEB_CONCURRENCY=1`; drain buffer set (Railway).
- [ ] Egress allowlist names only the hosts the tools actually call.
- [ ] Litestream on **and** a restore exercised — or the risk explicitly accepted.

## Hard constraints

- **Never raise `WEB_CONCURRENCY` to "fix" throughput.** The failure it causes is a
  reply delivered to the wrong customer — read
  [`docs/DEPLOY.md`](../DEPLOY.md) § The process model before proposing any scaling.
- **`_ALLOW_HTTP`/`_ALLOW_PRIVATE` never in cloud.** They exist for fully-local loops.
- **The onboarding surface (`/start.md`, `/docs`) is opt-in in production**
  (`INSIKA_ONBOARDING=1`) — leaving it off is the default posture, not a bug.
- **Report every deviation.** A var you had to add, a check that failed and was
  worked around, a step the platform made impossible — findings, not noise.
