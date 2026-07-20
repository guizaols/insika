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

## Requirements

- Ruby `>= 3.3` (pinned to `4.0.6` in `.ruby-version`)
- An LLM provider key (the demo uses DeepSeek)

## Quickstart

```bash
bundle install

# Single-process server (control UI + API) on :9292, seeded with a demo agent "bia".
DEEPSEEK_API_KEY=sk-... ruby scripts/serve_real.rb
```

First turn over the drop-in API (SSE):

```bash
curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" \
  -H "Content-Type: application/json" \
  -d '{"model":"bia","user":"chat-1","stream":true,"input":"hi, what can you do?"}'
```

Or open the control UI at **http://localhost:9292/studio** (log in with the token
`local-demo`) to create agents, edit prompts/skills/tools, and watch turns live.

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

## Status

Pre-release — APIs may still change. Name, license, and the full docs site are part
of an in-progress OSS-readiness pass.
