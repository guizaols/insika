---
title: Observability
parent: Operate & prove it
nav_order: 1
permalink: /observability/
---

# Observability — OpenTelemetry (opt-in)

Insika already has an observability spine: the **event stream**. Every turn emits
structured events (`task_started`, `tool_call`/`tool_result`, `data_tool_call`,
`task_completed`/`task_failed`/`task_cancelled`), each stamped with
`task_id`/`session_id`/`seq`/`at`. The OpenTelemetry bridge is a **consumer** of
that stream: it translates the events into OTEL **spans** and **metrics**. The core
(Executor, tools) never gains an OTEL call — events observe, telemetry translates.
It's the same "events observe" principle the SSE surface already uses.

Not every event on the stream is a turn. Operator actions, refinement runs
(`:refinement_started`, `:refinement_report`, `:refinement_proposed`,
`:refinement_gated`, `:refinement_applied`, `:refinement_rejected` — see
[Refinement](REFINEMENT.md)),
authoring writes (`:golden_written`, `:agent_file_written`, …), queue bookkeeping
(`:turn_coalesced`, `:turn_steered`, `:turn_steer_released`, `:turn_interrupted` — see
[Agents](AGENTS.md#queue_mode--when-a-message-arrives-while-the-agent-is-busy)) and
channel delivery (`:channel_delivered` — see [Channels](CHANNELS.md))
travel the same stream and are **ignored** by the bridge: they open no span and
touch no instrument, because they are not part of a turn's latency or cost. Any
other subscriber still sees them.

They are worth subscribing to even so, because each is the ONLY record of
something that left no task of its own behind:

| Event | Data | What it answers |
|---|---|---|
| `:turn_coalesced` | `task_id`, `merged`, `arrivals[]` | the fragments a customer typed in a row arrived as separate messages, and when |
| `:turn_steered` | `task_id`, `count`, `total` | a message arrived mid-run and was appended to the turn in flight |
| `:turn_steer_released` | `task_id`, `released_as`, `count` | the run could not absorb it, so it became the turn `released_as` |
| `:turn_interrupted` | `task_id`, `replaced_by` | the turn was abandoned mid-run, and which turn replaced it |
| `:turn_stuck` | `task_id`, `agent`, `reason`, `message` | the agent declared it could not proceed (`signal_stuck`, WS5) — the deterministic signal a consumer escalates on |
| `:channel_delivered` | `channel`, `outbox_id`, `status`, `attempts`, `error` | the answer reached the platform (or did not) — the turn completing says nothing about that |
| `:delivery_failed` | `channel`, `outbox_id`, `status`, `attempts`, `error` | a delivery exhausted its bounded retries — the alert face of the row above (WS6) |
| `:budget_warning` | `agent`, `tenant`, `window`, `spent`, `cap` | a calendar budget crossed its threshold (`alert_at` or a soft cap) — once per window (WS2) |
| `:breaker_open` | `agent`, `ref`, `tenant` | the reliability circuit breaker tripped for a `(tenant, provider/model)` — further turns fail fast until the cooldown (WS3/WS6) |
| `:provider_failure` | `agent`, `ref`, `error`, `kind` | one attempt against `ref` failed and spent a retry — emitted with or without a circuit breaker (WS3) |
| `:provider_fallback` | `agent`, `from`, `to`, `error`, `kind` | the turn ROTATED mid-flight to the next node of the fallback chain, and the error that caused it (WS3) |
| `:ttft` | `task_id`, `session_id`, `ttft_ms` | the provider's time-to-first-token on the streaming envelope — only under `INSIKA_TURN_TIMING`, once per turn (WS6) |

`delivery_failed` and `breaker_open` are the two the operator config is pointed at
(`alerts.webhook` on the profile): each only fires when something durable did
not land. `:ttft` is additive debug, absent unless `INSIKA_TURN_TIMING` is set.

`:channel_delivered` is the one worth alerting on: a turn can be `:task_completed`
and correct while the customer got nothing, because delivery is a separate,
retried, out-of-band step. `status: "failed"` means the reply is sitting in the
outbox and the customer is still waiting.

Counts, ids and times only — never message content. The text lives in the
transcript, which is the surface that is allowed to carry it.

The bridge speaks the standard the market already runs on: point any OTLP backend
at Insika and a real turn shows up as a full trace, next to counters and histograms
you can chart without touching a span.

**This page is a convention, not an integration.** Insika ships no dashboard, no
backend config, no vendor file. It ships a stable set of attribute and instrument
names, and the recipes below tell you what to chart against them — in whatever you
already run.

## Contents

- [Turning it on](#turning-it-on-opt-in-parity-when-off)
- [Traces: the span reference](#traces-the-span-reference)
- [Metrics: the instrument reference](#metrics-the-instrument-reference)
- [Attribute reference](#attribute-reference)
- [Estimated cost](#estimated-cost)
- [Dashboards you can build](#dashboards-you-can-build)
- [Stability contract](#stability-contract)
- [Local: a standalone collector](#local-a-standalone-collector)
- [Production](#production)
- [Design (why it's safe)](#design-why-its-safe)

## Turning it on (opt-in, parity when off)

Enabled by environment — no new code flag:

- `INSIKA_OTEL=1`, **or**
- the standard OTEL envs (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_EXPORTER`).

Destination, protocol and headers follow the **OTEL SDK's default config** (env):
point `OTEL_EXPORTER_OTLP_ENDPOINT` at your collector. `OTEL_SERVICE_NAME` names
the service (default `insika`).

Metrics ride the same switch and the same standard env — no Insika-specific toggle
is invented for them. `OTEL_METRICS_EXPORTER=none` turns metrics off while traces
stay on; `OTEL_METRIC_EXPORT_INTERVAL` (ms) sets the export period. If the metrics
SDK is not in the bundle at all, the bridge degrades to traces only rather than
failing to boot.

**Off (the default):** `Insika::Telemetry.setup` returns `nil`, the OTEL gems are
**never loaded** (lazy `require`, like the LLM client), and nothing is
instrumented — zero overhead. This is enforced by a test
(`spec/insika/load_guard_spec.rb`: "require insika does not load
OpenTelemetry").

## Traces: the span reference

One span per **turn**, with **child spans** per tool, correlated by `task_id`.
Latency is the span duration, reconstructed from the events' real `at` timestamps.

| Span | Emitted for | Parent |
|------|-------------|--------|
| `insika.turn` | one per turn, opened on `task_started`, closed on the terminal event | root |
| `insika.tool` | one per tool call, `tool_call` → `tool_result` (FIFO-correlated) | `insika.turn` |
| `insika.data_tool` | one per data-tool call — point-in-time (the engine emits a single event) | `insika.turn` |

A turn that ends with `task_failed` also carries the OTEL **error status**, with
the failure message.

## Metrics: the instrument reference

The same events feed instruments, so volume, latency, tokens and cost are chartable
**without aggregating spans** — which not every backend does, and none does cheaply
at retention. Metrics are recorded on the *terminal* event, so every point already
knows its outcome.

| Instrument | Type | Unit | Recorded when |
|------------|------|------|----------------|
| `insika.turns` | counter | `{turn}` | a turn reaches a terminal state |
| `insika.turn.duration` | histogram | `s` | same, when both timestamps are known |
| `insika.tokens` | counter | `{token}` | the turn reported usage |
| `insika.cost` | counter | `{USD}` | the turn's model is priced (see below) |
| `insika.tool.calls` | counter | `{call}` | a tool call completes |
| `insika.tool.duration` | histogram | `s` | a `tool_call`/`tool_result` pair completes |

`insika.tool.duration` is deliberately **not** recorded for data-tools: those are a
single point-in-time event, so there is no measured duration to report. A tool left
open by a mid-turn failure is not counted as a completed call either — its span is
closed, but a failed call must not inflate the success histogram.

## Attribute reference

The same names are used on spans and on metrics. **Metrics carry a deliberate
low-cardinality subset** — `task_id` and `session_id` are span-only, because a
metric attribute with per-turn cardinality is how you destroy a metrics backend.

| Attribute | Type | On spans | On metrics | Meaning |
|-----------|------|----------|------------|---------|
| `insika.task_id` | string | `turn` | — | the turn's id (correlates with `/v1/responses`, the Studio, the task store) |
| `insika.session_id` | string | `turn` | — | the chat this turn belongs to |
| `insika.agent` | string | `turn` | all | the agent profile that ran the turn |
| `insika.tenant` | string | `turn` | all | the **operator-set** tenant (see below); absent when the command declared none |
| `insika.command` | string | `turn` | all | command type (`send_message`, `trigger_workflow`, …) |
| `insika.status` | string | `turn` | turn instruments | `ok` / `error` / `cancelled` / `abandoned` |
| `insika.model` | string | `turn` | all except tool | model id the provider reported |
| `insika.model_source` | string | `turn` | — | which config layer resolved the model (chat / agent / model / global) |
| `insika.tokens.input` | int | `turn` | — | input tokens (**includes** the cached ones) |
| `insika.tokens.output` | int | `turn` | — | output tokens |
| `insika.tokens.total` | int | `turn` | — | input + output |
| `insika.tokens.cached` | int | `turn` | — | cache **reads**, a subset of `tokens.input` |
| `insika.tokens.cache_creation` | int | `turn` | — | cache **writes**, *not* inside `tokens.input` |
| `insika.token.type` | string | — | `insika.tokens` | `input` / `output` / `cached` / `cache_creation` |
| `insika.cost.usd` | double | `turn` | — | estimated cost of the turn (span attribute; the metric is the `insika.cost` counter) |
| `insika.tool` | string | `tool`, `data_tool` | tool instruments | tool name |
| `insika.tool.kind` | string | — | tool instruments | `tool` / `data_tool` |
| `insika.http.status` | int | `data_tool` | `insika.tool.calls` | HTTP status the data-tool got back |

### `insika.tenant`

The tenant is the **explicit** tenant of the Command (`Command.build(…, tenant:)`)
— the one grouping label an operator sets deliberately, typically the merchant,
workspace or customer the turn belongs to. It is **not** the memory scope, which
falls back to the chat id: putting per-chat cardinality on a metric attribute is
exactly the failure this distinction avoids. A command with no tenant emits **no
attribute at all**, rather than a null or an `"unknown"` bucket.

### Cardinality budget

Metric cardinality is roughly `agents × tenants × models × statuses × commands`
(and `agents × tenants × tools` for the tool instruments). All of those are
operator-controlled and closed-ish sets. Keep them that way: if you find yourself
wanting per-chat or per-user metrics, that is a **trace** query, and the span
attributes are there for it.

## Estimated cost

Insika ships **no prices**. They change weekly, differ per contract and per region,
and a stale table inside the engine would be worse than no number. You declare the
rates; Insika multiplies. Unset, no cost is reported anywhere.

Set `INSIKA_MODEL_PRICING` to a JSON object of model id → rates in **USD per
million tokens**:

```bash
INSIKA_MODEL_PRICING='{
  "deepseek-v4-flash":       {"input": 0.27, "output": 1.10, "cached_input": 0.07},
  "claude-sonnet-4-5":   {"input": 3.00, "output": 15.00, "cached_input": 0.30, "cache_write": 3.75}
}'
```

- A key matches the model id the provider reports, **with or without** the
  `provider/` prefix — `deepseek/deepseek-v4-flash` and `deepseek-v4-flash` both hit the
  same entry.
- `input` / `output` are required (one of them is enough for the entry to load).
- `cached_input`, when given, bills cache **reads** at that rate and subtracts them
  from the fresh input. Omit it and cached tokens simply stay at the input rate.
- `cache_write`, when given, bills cache **creation** tokens at that rate. Omit it
  and they are billed at the input rate.
- An **unpriced model reports nothing** — no attribute, no metric point. A missing
  price is not a zero cost, and a dashboard should show the gap.
- A malformed table degrades to "no cost". Telemetry config can never stop a boot.

The number is an **estimate for trend and attribution**, not a bill. Reconcile
against your provider's invoice, never the other way round.

## Dashboards you can build

Written against the convention, not against a product. Each recipe is
*instrument → aggregation → group-by*; the PromQL line is one illustration of the
shape, and translates directly to whatever query language your backend uses.

> **Names get normalized.** Prometheus-style backends rewrite OTLP names: dots
> become underscores, counters gain `_total`, and a real (non-annotation) unit is
> appended — so `insika.turn.duration` in `s` becomes
> `insika_turn_duration_seconds`. Annotation units like `{turn}` are dropped.
> Check your exporter's mapping; the convention below is the OTLP spelling.

**Turn volume by agent**
`insika.turns`, rate, grouped by `insika.agent`.
```promql
sum by (insika_agent) (rate(insika_turns_total[5m]))
```

**Error rate by agent** — the single most useful panel.
`insika.turns` filtered to `insika.status="error"`, over the same counter unfiltered.
```promql
sum by (insika_agent) (rate(insika_turns_total{insika_status="error"}[5m]))
  / sum by (insika_agent) (rate(insika_turns_total[5m]))
```

**Latency p95 by agent**
`insika.turn.duration`, 95th percentile, grouped by `insika.agent`.
```promql
histogram_quantile(0.95, sum by (le, insika_agent) (rate(insika_turn_duration_seconds_bucket[5m])))
```
Turn latency is dominated by the provider, not by the engine — see
[BENCHMARK.md](BENCHMARK.md) for the engine's own overhead, which is sub-millisecond
and will not show up here.

**Token burn by model**
`insika.tokens`, rate, grouped by `insika.model` and `insika.token.type`. Splitting
by type is what makes the cache visible: a healthy prompt cache shows `cached`
climbing while `input` stays flat.

**Cache hit ratio**
`insika.tokens` filtered to `insika.token.type="cached"` over the same counter
filtered to `input`. This is the number that moves your bill.

**Spend per tenant**
`insika.cost`, rate (or `increase` over a billing window), grouped by
`insika.tenant`. Swap the group-by for `insika.agent` to get spend per agent — the
same attribution the per-agent token ceilings in [SECURITY.md](SECURITY.md) act on.

**Tool reliability**
`insika.tool.calls`, rate, grouped by `insika.tool`; for data-tools add
`insika.http.status` to see which upstream is failing. Pair it with
`insika.tool.duration` p95 grouped by `insika.tool` to find the slow one.

**Workflows vs chats**
Any turn instrument grouped by `insika.command` — `trigger_workflow` and
`send_message` have very different latency and token profiles, and mixing them in
one average hides both.

**From a chart to the actual conversation**
Every panel above is grouped by attributes that also exist on the `insika.turn`
span. Filter your trace view by the same `insika.agent` / `insika.tenant` /
`insika.status`, open a trace, and `insika.task_id` and `insika.session_id` take you
to the exact turn in the Studio.

## Stability contract

These names are an interface. Dashboards, alerts and recording rules are built on
top of them, and renaming one breaks all of them silently — a chart does not error,
it just goes flat.

- Instrument names, units and attribute keys on this page are **stable**. They
  change only in a major version, and only with a note in `CHANGELOG.md`.
- Growth is **additive**: new attributes and new instruments may appear in a minor
  version. Do not write a query that assumes a fixed attribute set.
- An attribute whose value is unknown is **omitted**, never emitted as `null`,
  `""` or `"unknown"`. Handle absence in your queries rather than expecting a
  placeholder bucket.
- Everything under `insika.*` is ours. Standard OTEL resource attributes
  (`service.name`, and so on) come from the SDK and follow OTEL's own conventions.

## Local: a standalone collector

To see traces on your machine, run a standalone OTLP collector — the quickest is
Jaeger all-in-one (OTLP on `4318`, UI on `16686`):

```bash
docker run --rm -d --name jaeger \
  -p 16686:16686 -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

Then boot the engine with OTEL enabled, pointed at the collector:

```bash
INSIKA_OTEL=1 OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
  DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

`serve_real` prints `OTEL → on (traces + metrics to OTLP)` on boot. Chat at
`http://localhost:9292/studio` and open the traces at
**`http://localhost:16686`** (service `insika`): one `insika.turn` span per turn,
with `insika.tool`/`insika.data_tool` children and the attributes above. Stop the
collector with `docker rm -f jaeger`.

Jaeger stores traces only — to see the metrics too, point the same endpoint at an
OTLP collector that fans out to a metrics store, or add `OTEL_METRICS_EXPORTER=none`
to silence the metrics exporter's retries while you work on traces.

> We don't version a `docker-compose` file — the collector is standalone, a
> local run-it decision. The one-liner above is the whole recipe.

## Production

Set the OTEL envs on the deployment and every worker exports to your collector:

```bash
INSIKA_OTEL=1
OTEL_EXPORTER_OTLP_ENDPOINT=https://<your-collector>:4318
OTEL_SERVICE_NAME=insika        # optional; names the service
INSIKA_MODEL_PRICING='{...}'    # optional; unlocks the cost attribute + counter
# plus any standard OTEL_EXPORTER_OTLP_HEADERS your backend needs
```

The bridge is attached once, at boot, on the serving reactor — in `config.ru`,
`scripts/serve_real.rb` and the DSL's `serve` (so `Insika.agent { … }.serve` exports
too). It subscribes to the event stream in a long-lived fiber, sibling to serving.

## Design (why it's safe)

- **`Telemetry::Recorder`** — pure: translates event → spans and instruments against
  a duck-typed `tracer` (`start_span`/`set_attribute`/`record_error`/`finish`) and
  `meter` (`create_counter`/`create_histogram`). It does not reference
  `OpenTelemetry::` and is unit-tested with fakes. `record` **never raises**
  (telemetry must not bring down a turn); orphan events are ignored; tool
  correlation is FIFO; abandoned turns (e.g. `kill -9`, no terminal event) are
  bounded and evicted (`MAX_OPEN`) and counted as `status="abandoned"`.
- **`Telemetry::Pricing`** — pure: an operator-declared rates table times the turn's
  usage. No network, no bundled price list, no exception path.
- **`Telemetry.setup`** — the gem boundary: lazy `require` + configures the SDK +
  returns a `Recorder` wired to the real tracer and meter. Covered by a smoke test
  against the **real OTEL SDK** with in-memory exporters (span name/attributes/
  hierarchy/error status; instrument names/units/attributes).
- **No reader means no meter.** If every metric reader is disabled, `setup` injects
  no meter at all. Recording into a provider nothing drains would accumulate a point
  per attribute set forever — a slow leak dressed as telemetry.
- **`Telemetry.attach`** — subscribes the recorder to the event stream inside the
  reactor. No-op when the recorder is `nil` (disabled path), before touching the
  reactor.

## Backpressure

Each event-stream subscription is capped at 1000 buffered events; a telemetry
consumer that fell far behind would have its subscription closed (telemetry stops,
the turn does not). Span and instrument operations are cheap, so there's ample
headroom.

## Process vitals — `GET /v1/vitals`

OTel carries turn/tool telemetry; it says nothing about the **process**. For the
questions a soak (or any operator) asks — *which process is this, how long has it
been up, how much memory does it hold, and what is the Ruby heap doing?* — there
is one read-only route:

```bash
curl -H "Authorization: Bearer $TOKEN" https://<target>/v1/vitals
```

```jsonc
{
  "boot_id": "20260820T09-…",     // one per container start; a change = a restart
  "pid": 42,
  "started_at": "2026-08-20T09:00:00Z",
  "uptime_s": 259200,
  "version": "0.2.0",
  "ruby": "ruby 3.4.1 …",
  "yjit": true,
  "rss_bytes": 536870912,          // nil when unreadable — never a guess
  "gc": { "heap_live_slots": …, "major_gc_count": …, "malloc_increase_bytes": … },
  "threads": 8,
  "in_flight": 1,                  // the executor's in-flight turns
  "db_bytes": { "db": …, "wal": …, "shm": … },
  "at": "2026-08-20T09:00:00Z"
}
```

The two fields that make it a **restart detector**: `boot_id` (one per container
start, exported by the entrypoint and shared by every worker) and `pid`. A
`boot_id` change is a container restart; a `pid` change under the same `boot_id`
is a worker respawn — the event a platform metrics API cannot see.

- **Operator-only.** The route is not in the public allowlist (no bearer →
  unauthorized) and not on the tenant surface, so only an operator reads
  process internals. `/up` stays the public health probe and carries no
  process data.
- **Reads no store.** Pure OS/VM readings — safe to poll at any rate, and it
  cannot contend with turns.
- **The soak's sampler.** [Soak](SOAK.md) polls it hourly; a `nil` RSS reads as
  missing coverage, never as zero.

---

*Packaging note.* Today the bridge lives in the Insika repo as an opt-in core
module — no separate install, no separate versioning. When Insika extracts its
subsystems into gems it becomes `insika-otel`; because the bridge is already a
pure event-stream consumer with a single gem boundary, that cut lands clean.
