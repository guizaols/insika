# SOAK — the pre-declared envelope for the 72h run

> **Frozen on:** <YYYY-MM-DD>, before the first soak hour was fired.
> **Applies to:** the soak protocol defined in RFC-0026.
> **Editing this file invalidates the running window.** Every hourly snapshot
> records the SHA-256 of this file; a run whose snapshots disagree produces
> `invalid`, never a verdict. That is the point.

## What is being measured

A production-shaped deploy — **one process**, SQLite, Litestream, recovery and
drain on — carrying a representative conversational load without interruption for
72 hours. The question is **degradation over uptime**, not capacity. The claim
under test is cut argument #1: the incumbent's latency grew with uptime
(4.9 s → 14.6 s observed) and Insika's does not.

## What is gated, and what is only reported

The **gate** is on what the engine owns: the local per-turn work (`prep_ms` —
context build, policy, guardrail detectors, chat assembly), resident memory,
restarts, and errors.

Time-to-first-token is **reported and never gated**. It was measured at ~720 ms
and shown to be ~100% provider — connection pooling, local assembly and reasoning
were each falsified as levers. Gating on a number the engine cannot move would
mean failing a clean soak because the provider had a bad afternoon, and then
loosening the envelope, which this protocol forbids.

End-to-end latency **is** reported hour by hour, because that is the series the
cut argument is made with. It carries only a catastrophe ceiling.

## The envelope

```yaml
version: 1
target: staging                       # staging | store:<id>
target_url_host: <fill in>            # preflight P5 refuses a mismatch
agent: soak-<store>                   # its own agent, its own tenant
tenant: soak

duration_hours: 72
warmup_hours: 6                       # excluded from every fit and every window

# --- load shape ---
arrival: poisson
turns_per_hour: 60                    # ← the one number to check against reality
session_turns: 7
concurrency_cap: 8
request_timeout_s: 120
corpus: evals/soak/corpus.txt

# --- isolation (part of the pre-declaration, not an afternoon decision) ---
web_concurrency: 1
chat_rate_limit: 0                    # 0 = the platform default is off FOR THIS AGENT
agent_token_ceiling: 0                # the prod ceiling admits ~10 turns/h at ~48k/turn
turn_timing: required

# --- gated, frozen now, no calibration needed ---
rss_growth_ratio: 1.15                # upper 95% bound of the OLS fit, hour 6 -> hour 72
prep_p95_drift_ratio: 1.50            # last 6h vs first measured 6h
restarts_max: 0                       # any boot_id OR pid change is a fail
error_rate_ceiling: 0.005
no_usage_rate_ceiling: 0.002          # a turn with no usage called no model
coverage_min_ratio: 0.95              # hours with a usable vitals snapshot
gap_seconds_max: 900
hourly_turn_floor: 30                 # an hour below this is insufficient, not passing

# --- gated, calibrated by E1, written before E2 (formula: E1 value x 2) ---
rss_ceiling_mb:                       # <from E1>
prep_p95_ceiling_ms:                  # <from E1>
total_p95_ceiling_ms:                 # <from E1>  (deliberately loose: catastrophe only)

# --- reported, never gated ---
report_only:
  - ttft_p95_ms
  - total_p95_hourly
  - rss_slope_mb_per_day
  - heap_growth_ratio
  - db_growth_mb
  - cost_usd
  - tokens_per_turn
```

## The verdict, in words

Over **72 consecutive hours** at **60 turns/hour**, with at least **30 turns and
one vitals snapshot in every hour**, the run passes when:

1. **memory does not trend up** — fitting resident memory against time from hour 6
   onwards, the *upper* 95% bound of the slope implies no more than **15% growth**
   across the remaining 66 hours. The upper bound, not the point estimate, because
   at 66 points noise alone produces a slope;
2. **local per-turn work does not drift** — p95 of `prep_ms` in the last 6 hours is
   no more than **1.5×** its value in the first measured 6 hours;
3. **the process never restarted** — one `boot_id`, one `pid`, for 72 hours;
4. **errors stay under 0.5%**, and **under 0.2% of successful turns called no
   model** (a turn with no `usage` block was answered by the edge limiter or a
   halt, not by the agent — that is the failure mode in which a broken soak looks
   perfect);
5. the calibrated absolute ceilings are not breached.

The verdict is `insufficient` — not `fail` — when coverage is short: a gap over
15 minutes, an hour under 30 turns, or a runner that did not reach hour 72. Short
coverage restarts the window; it never gets rounded up into a pass.

The verdict is `invalid`, and **no metric is reported at all**, when the run's
snapshots carry more than one hash of this file, when more than one process id
appears under one boot generation (the memory series is then not one process), or
when the file is materially truncated.

## Deploys are frozen for the window

Any restart is a fail, including a deployment. There is no "declared deploy"
exception: a marker the operator writes after the fact would turn every crash into
a deploy. Freeze the target for 72 hours, or spend 72 hours again.

## Why these numbers

| Number | Why |
|--------|-----|
| `duration_hours: 72` | RFC-0026. A leak that shows at hour 40 is invisible to a 10-minute bench; three days crosses two daily `Retention` sweeps and two full cache-expiry cycles. |
| `warmup_hours: 6` | A Ruby process reaching steady heap is not a leak. Six hours is generous enough that the fit measures the plateau, short enough to leave 66 points. |
| `rss_growth_ratio: 1.15` | Non-inferiority, not perfection: the claim is "does not tax uptime", so a plateau with allocator noise passes and a trend does not. A ratio rather than MB/day so the same envelope reads correctly on any box, which RFC §4.4's per-store re-run requires. |
| `prep_p95_drift_ratio: 1.50` | Loose on purpose. Local work is sub-millisecond, so its p95 is dominated by scheduling jitter; a 1.1 bar would measure the box. 1.5× still catches an unbounded structure growing per turn — which is what a real degradation would look like here. |
| `restarts_max: 0` | The whole claim is about uptime. A restart resets exactly the thing being measured, and `railway.json` restarts on failure with 3 retries — silently, unless this is counted. |
| `no_usage_rate_ceiling: 0.002` | The edge limiter answers a breach with a canned reply, zero LLM calls and HTTP 200. Without this rule a soak that ran entirely into the limiter reports a flat 2 ms p95 and passes. |
| `hourly_turn_floor: 30` | Half the declared rate. Prevents a quiet stretch from being averaged into a full window. |
| `coverage_min_ratio: 0.95` | Up to ~3 lost hours of vitals tolerated; more and the memory series has holes the fit would paper over. |
| `turns_per_hour: 60` | **Provisional.** Shaped like the pilot, not measured. At ~48k tokens/turn this is ~2.9M tokens/hour and roughly $10–20 of provider spend for the whole 72h — cost is not a reason to run this thin. |

## What this envelope does NOT decide

It does not gate the pre-merge suite and no baseline reads it. It answers
**H-soak** for one deploy: green at 0.4 says the cut is possible at all; green per
store before that store's cut is the 1.0 gate. A fail means find the leak — never
cut, never loosen this file.
