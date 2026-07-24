# Running the Harness locally

Boots the engine single-process, serving `/studio` and `/v1/*` against a demo
agent (the `bia` persona on DeepSeek). Every message runs the **same**
`send_message` the API runs — real tools, skills, and memory.

## Boot

```bash
cd harness
DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

> Use **`bundle exec`** (bundler isolation matters — the optional OpenTelemetry gem
> is in the Gemfile). It is single-process: `Ctrl-C` frees the port immediately.

Open `http://localhost:9292`:

| URL | What |
|-----|------|
| `/studio` | management UI (log in with the token; default `local-demo`) |
| `/studio/chats` | chat with the demo agent (`agent: bia`, `session_id: web`, multi-turn ready) |
| `/studio/tasks` | tasks / approvals console |
| `/v1/responses` | OpenAI-Responses ingress (Bearer) — the drop-in API contract |
| `/v1/agents` | provisioning by definition/pack (Bearer) — `POST` imports, `DELETE /:id` removes |
| `/v1/messages` | `send_message` sugar (SSE when `?stream` is set) |

## Variables (all optional)

| Env | Default | Effect |
|-----|---------|--------|
| `INSIKA_DB` | — (ephemeral memory) | SQLite path → config + execution survive a restart |
| `BIND` | `http://localhost:9292` | host:port |
| `ADMIN_TOKEN` | `local-demo` | token for `/studio` |
| `OPENCLAW_GATEWAY_TOKEN` | falls back to `ADMIN_TOKEN` | Bearer for `/v1/responses` and `/v1/agents` |
| `DEEPSEEK_MODEL` | `deepseek-chat` | model |

With persistence:

```bash
DEEPSEEK_API_KEY=sk-... INSIKA_DB=./harness.db bundle exec ruby scripts/serve_real.rb
```

## Pointing a Responses client at the local engine

Anything that speaks the OpenAI Responses contract can drive the local engine —
that is the whole point of the `/v1/responses` drop-in. Point your client's base
URL at `http://localhost:9292`, send the API Bearer, and address an agent by id as
the `model`:

```bash
curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" \
  -H "Content-Type: application/json" \
  -d '{ "model": "bia", "user": "web", "stream": true, "input": "hello" }'
```

`user` is the session id (any stable id for a multi-turn conversation).

## Wiring an agent's tools back to your backend

If the agent has **data-tools** that call your own HTTP backend (see
[Tools](TOOLS.md)), and both the engine and that backend run on your machine, the
tools target `http://localhost:<port>/…` — plain `http` on a loopback address,
which the egress guard blocks by default (SSRF defense). Enable the opt-in
**pinned to your backend's host** when you boot:

```bash
INSIKA_EGRESS_ALLOW_HTTP=1 INSIKA_EGRESS_ALLOW_PRIVATE=1 \
INSIKA_EGRESS_HOSTS=localhost,127.0.0.1 \
DEEPSEEK_API_KEY=sk-... bundle exec ruby scripts/serve_real.rb
```

> `INSIKA_EGRESS_HOSTS` restricts the opened egress to just the internal host
> (defense-in-depth) — without it, `ALLOW_PRIVATE` opens *any* private destination.
> These `ALLOW_*` vars are for the fully-local loop only; never set them in the
> cloud. See [Security](SECURITY.md#egress-the-ssrf-boundary).

## Provisioning an agent

An agent is created from a **definition** — a folder ("pack") with an agent config,
prompt files, skills, and one data-tool per file:

```
<pack>/
  agent.config.json     # { id, model, provider, memory, metadata }
  *.md                  # prompt files (identity, tools notes, …)
  skills/<name>/SKILL.md
  tools/<tool>.json     # one data-tool per file
```

> **Data-tool URLs must be literal on the pack path.** The pack import does not
> resolve `{{env.*}}` — bake the backend base URL into each `tools/*.json` at
> generation time. (Only the *manifest* path resolves `{{env.*}}`.) See
> [Tools](TOOLS.md#the-one-gotcha-env-templating-is-manifest-only).

Provision it (runs as a client against the live server; the internal token comes
from the environment, never disk):

```bash
INSIKA_URL=http://localhost:9292 OPENCLAW_GATEWAY_TOKEN=local-demo \
  bundle exec ruby scripts/import_pack.rb /path/to/pack
```

…or `POST /v1/agents` directly, or build the agent by hand in the `/studio`. All
paths land on the same import. See [Agents](AGENTS.md) for the from-scratch flow
and the `Harness.agent { … }` DSL.

## Observability (OpenTelemetry, opt-in)

OpenTelemetry is **off by default** (the gem does not even load). To turn it on,
see traces in a local collector (a one-line Jaeger), and the production config, see
[OBSERVABILITY.md](OBSERVABILITY.md). In short: `INSIKA_OTEL=1` +
`OTEL_EXPORTER_OTLP_ENDPOINT=…`, and every turn becomes a `harness.turn` trace with
`harness.tool` / `harness.data_tool` children.

## See also

- [Agents](AGENTS.md) — create and configure an agent.
- [Tools](TOOLS.md) — define data-tools and troubleshoot egress.
- [Deploy](DEPLOY.md) — running the same image durably in a container.
