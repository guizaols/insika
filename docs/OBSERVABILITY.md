# Observability — OpenTelemetry (opt-in)

Harness already has an observability spine: the **event stream**. Every turn emits
structured events (`task_started`, `tool_call`/`tool_result`, `data_tool_call`,
`task_completed`/`task_failed`/`task_cancelled`), each stamped with
`task_id`/`session_id`/`seq`/`at`. The OpenTelemetry bridge is a **consumer** of
that stream: it translates the events into OTEL spans. The core (Executor, tools)
never gains an OTEL call — events observe, telemetry translates. It's the same
"events observe" principle the SSE surface already uses.

The bridge speaks the standard the market already runs on: point any OTLP backend
(Grafana Tempo, Datadog, Honeycomb, SigNoz, Jaeger, the OpenTelemetry Collector)
at Harness and a real turn shows up as a full trace.

## What you get

One span per **turn** (`harness.turn`), with **child spans** per tool
(`harness.tool`) and per data-tool (`harness.data_tool`), correlated by `task_id`.
Latency is the span duration, reconstructed from the events' real `at` timestamps.
Tokens/cost, agent and model ride as **attributes** — your backend aggregates them
into metrics, so Harness does not depend on the (less mature in Ruby) OTEL metrics
SDK.

| Span | Attributes |
|------|------------|
| `harness.turn` | `harness.task_id`, `harness.session_id`, `harness.agent`, `harness.command` |
| `harness.turn` (on finish) | `harness.tokens.input` / `.output` / `.total` / `.cached`, `harness.model` |
| `harness.turn` (on finish) | `harness.status` = `ok` / `error` / `cancelled` (+ OTEL error status on failure) |
| `harness.tool` | `harness.tool` (tool name) |
| `harness.data_tool` | `harness.tool`, `harness.http.status` |

## Turning it on (opt-in, parity when off)

Enabled by environment — no new code flag:

- `INSIKA_OTEL=1`, **or**
- the standard OTEL envs (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_EXPORTER`).

Destination, protocol and headers follow the **OTEL SDK's default config** (env):
point `OTEL_EXPORTER_OTLP_ENDPOINT` at your collector. `OTEL_SERVICE_NAME` names
the service (default `harness`).

**Off (the default):** `Harness::Telemetry.setup` returns `nil`, the OTEL gem is
**never loaded** (lazy `require`, like the LLM client), and nothing is
instrumented — zero overhead. This is enforced by a test
(`spec/harness/load_guard_spec.rb`: "require harness does not load
OpenTelemetry").

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

`serve_real` prints `OTEL → on (spans to OTLP)` on boot. Chat at
`http://localhost:9292/studio` and open the traces at
**`http://localhost:16686`** (service `harness`): one `harness.turn` span per turn,
with `harness.tool`/`harness.data_tool` children and the token/agent/model/latency
attributes. Stop the collector with `docker rm -f jaeger`.

> We don't version a `docker-compose` file — the collector is standalone, a
> local run-it decision. The one-liner above is the whole recipe.

## Production

Set the OTEL envs on the deployment and every worker exports to your collector:

```bash
INSIKA_OTEL=1
OTEL_EXPORTER_OTLP_ENDPOINT=https://<your-collector>:4318
OTEL_SERVICE_NAME=harness        # optional; names the service
# plus any standard OTEL_EXPORTER_OTLP_HEADERS your backend needs
```

The bridge is attached once, at boot, on the serving reactor (see
`config.ru` and `scripts/serve_real.rb`) — it subscribes to the event stream in a
long-lived fiber, sibling to serving.

## Design (why it's safe)

- **`Telemetry::Recorder`** — pure: translates event → spans against a duck-typed
  `tracer` (`start_span`/`set_attribute`/`record_error`/`finish`). It does not
  reference `OpenTelemetry::` and is unit-tested with a fake tracer. `record`
  **never raises** (telemetry must not bring down a turn); orphan events are
  ignored; tool correlation is FIFO; abandoned turns (e.g. `kill -9`, no terminal
  event) are bounded and evicted (`MAX_OPEN`).
- **`Telemetry.setup`** — the gem boundary: lazy `require` + configures the SDK +
  returns a `Recorder` wired to the real tracer. Covered by a smoke test against
  the **real OTEL SDK** with an in-memory exporter (span name/attributes/hierarchy/
  error status).
- **`Telemetry.attach`** — subscribes the recorder to the event stream inside the
  reactor. No-op when the recorder is `nil` (disabled path), before touching the
  reactor.

## Backpressure

Each event-stream subscription is capped at 1000 buffered events; a telemetry
consumer that fell far behind would have its subscription closed (telemetry stops,
the turn does not). Span operations are cheap, so there's ample headroom.

---

*Packaging note.* Today the bridge lives in the Harness repo as an opt-in core
module — no separate install, no separate versioning. When Harness extracts its
subsystems into gems it becomes `harness-otel`; because the bridge is already a
pure event-stream consumer with a single gem boundary, that cut lands clean.
