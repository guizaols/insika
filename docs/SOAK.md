---
title: Soak
parent: Operate
nav_order: 5
permalink: /soak/
---

# SOAK — does it degrade over uptime?

The soak is the third question the measurement toolbox answers, and it is the
one the other two cannot:

| Tool | Question | Drives |
|------|----------|--------|
| [`scripts/bench.rb`](BENCHMARK.md) | How much overhead does the engine itself add? | publishable claims |
| [Load test](LOADTEST.md) | What does a burst look like, end to end? | topology + provider choice |
| **`insika soak`** | **Does the deploy degrade over 72 hours of steady load?** | the cut argument: "it does not tax uptime" |

A load test fires a wave, joins it, and reports. A soak **sustains a declared
arrival rate for days** and asks whether the *process itself* — resident memory,
per-turn local work, restarts — degrades with uptime. A leak that only shows at
hour 40 is invisible to a 10-minute bench.

## The protocol in one paragraph

1. **Freeze the envelope first.** A deployment-side envelope file declares the
   load shape, the gated ceilings and the isolation contract — *before* the
   first turn is fired. Its SHA-256 is stamped into every hourly snapshot;
   editing it mid-run turns the run `invalid` instead of producing a verdict.
2. **Preflight.** `insika soak --preflight` refuses to start unless the target
   answers `/v1/vitals` with a readable RSS, turns carry the `INSIKA_TURN_TIMING`
   breakdown *and* a `usage` block, the pid is stable, and the target host
   matches the envelope. Each check is a named refusal, not a runtime warning.
3. **Run.** `insika soak --run` fires the arrival process (Poisson, seeded,
   concurrency-capped), polls vitals hourly, and appends every observation to
   `<out>/<run>.jsonl` as it happens — a runner that dies at hour 60 must
   leave 60 usable hours behind. No retry, no self-healing: a failed turn is
   evidence.
4. **Read the verdict.** `insika soak --verify <file>.jsonl.gz` recomputes the
   whole verdict offline from the raw records — no network, no target, no
   clock. Two people running it get the same answer; so does CI.

## What is gated, and what is only reported

The gate is on the part **Insika owns**:

| Gated (binding) | Reported (never gated) |
|-----------------|------------------------|
| `rss_growth_ratio` — upper 95% bound of the RSS fit, hour 6 → hour 72 | `rss_slope_mb_per_day`, `rss_peak_mb` |
| `prep_p95_drift_ratio` — p95 of the local per-turn work (`prep_ms`: context build, policy, guardrails, chat assembly), last 6 h vs first measured 6 h | `ttft_p95_ms`, `total_p95` hourly series |
| `restarts_max` — any `boot_id` **or** `pid` change is a fail; there is no "declared deploy" exception | `heap_growth_ratio`, `db_growth_mb` |
| `error_rate_ceiling`, `no_usage_rate_ceiling` | `cost_usd`, `tokens_per_turn` |
| calibrated absolute ceilings (written from the E1 dry run, ×2) | — |

Time-to-first-token is **reported, never gated**: it was measured at ~720 ms and
shown to be ~100% provider. Gating on a number the engine cannot move would mean
failing a clean soak because the provider had a bad afternoon — and then
loosening the envelope, which the protocol forbids.

The **`no_usage_rate`** ceiling is the trap detector. The edge limiter answers a
breach with a canned reply, zero LLM calls and HTTP 200 — so a soak that ran
entirely into the limiter looks like thousands of successful turns with a
gorgeous 2 ms p95 and flat memory. A turn with no `usage` block called no model;
the ceiling keeps that from reading as a pass.

## The isolation contract

- **Staging or a dedicated tenant, never a production tenant.** The run writes
  ~4,000 sessions and tasks into the store; against production that is
  synthetic data mixed into real customer history. The envelope names the
  tenant (`soak`), so `delete_tenant_data` cleans the entire run in one
  command.
- **Its own agent, with the edge limits off.** At a real ~48k tokens per turn,
  the production token ceiling admits about 10 turns per hour — a 60 turns/h
  soak against a production-configured agent measures its own limiter within
  minutes. `chat_rate_limit: 0` and `agent_token_ceiling: 0` on the soak agent
  are part of the frozen envelope, not an afternoon decision.
- **Deploys are frozen for the window.** Any restart is a fail, including a
  deployment — a marker the operator writes after the fact would turn every
  crash into a deploy.

## Running it

```bash
# the plan + one sample request, no traffic
insika soak --dry-run --envelope soak-envelope.md

# every precondition, and nothing else
insika soak --preflight --envelope soak-envelope.md

# the run itself (INSIKA_URL + INSIKA_GATEWAY_TOKEN, like loadtest.rb)
INSIKA_URL=https://<target> insika soak --run --envelope soak-envelope.md --out soak-out/

# resume after a short outage (the gap is recorded and counts against the window)
insika soak --run --resume soak-out/staging-2026-08-20T09-00-00Z.jsonl

# the verdict, recomputed offline — the only step that needs no target
insika soak --verify soak-out/staging-2026-08-20T09-00-00Z.jsonl.gz
```

Duration, rate and ceilings all come from the envelope — there is no
`--duration` override, so a short run cannot be passed off as a soak.

## Reading the verdict

`insika soak --verify` prints one of four, in this order of precedence:

- **`invalid`** — the snapshots carry more than one envelope hash, more than
  one process id appeared under one boot generation, or the file is materially
  truncated. **No metric is reported at all**; the file cannot be argued with.
- **`insufficient`** — coverage is short: a gap over 15 minutes, an hour under
  the turn floor, or a runner that did not reach hour 72. Short coverage
  restarts the window; it is never rounded up into a pass.
- **`fail`** — a gated ceiling was breached. The report names each one and
  prints the leak-hunt starting point: whether the Ruby heap grew with RSS
  (Ruby-side retention) or stayed flat while RSS climbed (allocator or a
  native buffer).
- **`pass`** — none of the above.

A fail means *find the leak* — never cut, and never loosen the envelope.

## See also

- [Observability](OBSERVABILITY.md) — `GET /v1/vitals`, the process readings
  the soak samples hourly.
- [Deploy](DEPLOY.md) — the process model; `WEB_CONCURRENCY=1` is a soak
  precondition, not only a queue-semantics one.
