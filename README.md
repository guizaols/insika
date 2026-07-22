# Harness

> **Working name.** The project name/namespace isn't final yet.

A Ruby runtime for **LLM agents in production**: a durable, resumable turn pipeline
behind an **OpenAI-Responses-compatible** HTTP API (`POST /v1/responses`), with tools,
skills, cross-session memory, per-agent policy, content-safety guardrails, and a web
control UI. Point an existing OpenAI-Responses client at it and serve many agents
from one deployment.

## Highlights

- **Drop-in `/v1/responses`** — SSE streaming and usage, the shape existing clients already speak.
- **Durable & resumable** — every turn checkpoints; a crash resumes without repeating side-effects.
- **Agents as data** — create/edit agents, prompts, skills and tools at runtime (UI or API), no redeploy.
- **Tools & skills** — code tools + data-defined tools, progressive skill loading, MCP import.
- **Memory** — cross-session facts and notes, per agent.
- **Guardrails** — content-safety (prompt-injection, PII/secret redaction, abuse) on input and output, opt-in and configurable per agent.
- **Observability** — an event stream, per-session tool-call traces, optional OpenTelemetry.
- **Negligible overhead** — the engine adds well under a millisecond per turn; a neutral, key-free benchmark reproduces it ([docs/BENCHMARK.md](docs/BENCHMARK.md)).

## Requirements

- Ruby `>= 3.3` (pinned to `4.0.6` in `.ruby-version`)
- An LLM provider key (the demo uses DeepSeek)

## Quickstart

Define an agent in Ruby and talk to it — the whole program:

```ruby
require "harness"

assistant = Harness.agent("assistant") do
  model "deepseek-chat"
  provider :deepseek
  instructions "You are Bia, a concise and friendly assistant. Answer briefly."
end

puts assistant.reply("hi, what can you do?")   # one turn, in-process
```

```bash
bundle install
DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb "hi, what can you do?"
```

Swap `reply` for `serve` and the same agent is a server — control UI (`/studio`)
plus the drop-in `/v1/responses` API on `:9292`:

```ruby
assistant.serve   # http://localhost:9292/studio  +  POST /v1/responses
```

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/quickstart.rb --serve
```

Then, over the drop-in API (SSE) — `model` is the agent id:

```bash
curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" \
  -H "Content-Type: application/json" \
  -d '{"model":"assistant","user":"chat-1","stream":true,"input":"hi, what can you do?"}'
```

The DSL is **thin sugar over config-over-code**: `Harness.agent { … }.to_pack` is a
plain provisioning pack — the same portable artifact you can create/edit at runtime
through the control UI or `POST /v1/agents`. Nothing is a bypass; the DSL just
*generates the data*. For the full demo deployment (real tools/skills/memory), see
`scripts/serve_real.rb`.

## The API

`POST /v1/responses` — Bearer token (`local-demo` in the demo):

| field    | meaning                                             |
|----------|-----------------------------------------------------|
| `model`  | the agent id (e.g. `"bia"`)                         |
| `user`   | chat / session id                                   |
| `input`  | the user message (string)                           |
| `stream` | `true` for Server-Sent Events                       |

Responses stream OpenAI-Responses SSE frames (`response.output_text.delta`,
`response.completed`, …). Provision more agents at runtime via `POST /v1/agents`
(pack import) or the control UI.

## Architecture (one turn)

```
Command Bus → Context Builder → Policy Engine → Middleware → Executor (tool-loop) → Event Stream / SSE
```

Durable stores (SQLite, or in-memory for dev) hold sessions, tasks and checkpoints.
A deeper architecture guide is in progress.

## Tests

```bash
bundle exec rspec
```

## More docs

- [docs/RUNNING-LOCAL.md](docs/RUNNING-LOCAL.md) — running locally, the control UI, OpenTelemetry.
- [docs/DEPLOY.md](docs/DEPLOY.md) — production deploy (Falcon, durable SQLite volume, tokens).
- [docs/LOADTEST.md](docs/LOADTEST.md) — load-testing and data-topology.
- [docs/BENCHMARK.md](docs/BENCHMARK.md) — the neutral, reproducible, provider-free engine benchmark.

## Status

Pre-release — APIs may still change. Name, license, and the full docs site are part
of an in-progress OSS-readiness pass.
