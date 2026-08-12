# Insika

**Your agent is the idea. Insika is what holds it up in production.**

*Insika* is Zulu for the pillar that carries a structure — the part nobody admires and
everything rests on. A turn that survives a crash, tools that cannot wander off, limits
that hold under load, and an API your clients already speak. Build the agent; the
scaffolding is already here.

---

Insika is a Ruby runtime for **LLM agents in production**: a durable, resumable turn
pipeline behind an **OpenAI-Responses-compatible** HTTP API (`POST /v1/responses`), with
tools, skills, cross-session memory, per-agent policy, content-safety guardrails, and a
web control UI. Point an existing Responses client at it and serve many agents from one
deployment.

- **Drop-in `/v1/responses`** — SSE streaming and usage, the shape existing clients already speak.
- **Durable & resumable** — every turn checkpoints; a crash resumes without repeating side-effects.
- **Agents as data** — agents, prompts, skills and tools are editable at runtime (UI or API), no redeploy.
- **Tools & skills** — code tools, data-defined tools, MCP import; skills load on demand.
- **Safe by default** — content-safety guardrails, an egress guard, confined execution, approvals, edge limits.
- **Observable** — an event stream, per-session tool-call traces, optional OpenTelemetry.
- **~0.4 ms of engine per turn** — p50 overhead on a neutral, key-free benchmark you can rerun yourself ([methodology](docs/BENCHMARK.md)).

## Your first agent

Ruby `>= 3.3` and a provider key (the demo uses DeepSeek). The whole program:

```bash
gem install insika
```

```ruby
require "insika"

assistant = Insika.agent("assistant") do
  model "deepseek-v4-flash"
  provider :deepseek
  instructions "You are Bia, a concise and friendly assistant. Answer briefly."
end

puts assistant.reply("hi, what can you do?")   # one turn, in-process
```

Swap `reply` for `serve` and the same agent is a server — the control UI at `/studio`
plus the drop-in API, on `:9292`:

```bash
DEEPSEEK_API_KEY=sk-... ruby quickstart.rb

curl -N http://localhost:9292/v1/responses \
  -H "Authorization: Bearer local-demo" -H "Content-Type: application/json" \
  -d '{"model":"assistant","user":"chat-1","stream":true,"input":"hi"}'
```

`model` is the agent id; `user` is the session id. The DSL is thin sugar over
config-over-code: `Insika.agent { … }.to_pack` emits the same portable pack you can
create or edit at runtime through the UI or `POST /v1/agents` — nothing in the DSL is a
bypass, it just generates the data. → [Agents](docs/AGENTS.md),
[Running locally](docs/RUNNING-LOCAL.md)

## Or let your coding agent build it

A running instance serves its own **LLM-first onboarding**. Point Claude Code, Cursor or
any IDE assistant at it and let it do the setup:

```
Read http://localhost:9292/start.md then help me build my first agent
```

`start.md` is a skill-structured prompt (gather context → decide → build → self-check →
guard against known failure modes). Alongside it: **`GET /models.json`** (configured
providers and model ids, the defaults, the valid `thinking` levels, the agent ids already
served — no secrets) and **`GET /docs`** + **`GET /docs/<name>.md`** (these docs as raw
markdown). Public and on by default when you `serve`; opt-in in production
(`INSIKA_ONBOARDING=1`).

## Docs by goal

**Understand the idea**

- [Why Insika](docs/WHY.md) — a runtime vs a DIY loop, an assembled framework, or a hosted gateway.
- [Architecture](docs/ARCHITECTURE.md) — the turn pipeline, the tool-loop, checkpoint recovery, composition roots, diagrams.

**Build an agent**

- [Agents](docs/AGENTS.md) — the AgentProfile and its five access layers; create and edit at runtime.
- [Tools](docs/TOOLS.md) — code vs data vs MCP tools, manifests, egress troubleshooting.
- [Skills](docs/SKILLS.md) — the SKILL.md format and progressive loading.
- [Context](docs/CONTEXT.md) — what fills a turn's prompt; budget, eviction, memory.
- [Workflows](docs/WORKFLOWS.md) — deterministic orchestration of several agents: the five patterns, and when to let the model choose instead.
- [Channels](docs/CHANNELS.md) — how people reach the agent: a widget on your site in one `<script>` tag, or keep your own WhatsApp/Slack stack (relay).
- [Plugins](docs/PLUGINS.md) — the two extension tiers: config-only, or a gem the engine loads.
- [Running locally](docs/RUNNING-LOCAL.md) — the local demo, the control UI, wiring tools to your own backend.
- [examples/](examples/) — one small runnable project per capability.

**Ship it**

- [Security](docs/SECURITY.md) — guardrails, egress, approvals, edge limits, secrets.
- [Sandbox](docs/SANDBOX.md) — the confined-execution primitive.
- [Deploy](docs/DEPLOY.md) — Falcon, a durable SQLite volume, tokens.
- [Embedding](docs/EMBEDDING.md) — mount Insika into the Ruby app you already have: `Insika.embed(backend:)` and a Rack app for your router.

**Operate & prove it**

- [Observability](docs/OBSERVABILITY.md) — OpenTelemetry (opt-in): turns as traces and metrics, the attribute convention, dashboard recipes.
- [Benchmark](docs/BENCHMARK.md) — the neutral, reproducible, provider-free engine benchmark.
- [Load test](docs/LOADTEST.md) — load-testing and data topology.
- [Evals](docs/EVALS.md) — the cases that grade an agent: rubrics, the judge panel, and the pre-merge gate.
- [Refinement](docs/REFINEMENT.md) — read an agent's own traffic back as a ranked report of what broke.

All of the above is also browsable, searchable and cross-linked at
**[guizaols.github.io/insika](https://guizaols.github.io/insika/)** — the same files,
rendered. Reading this repo as an agent? [llms.txt](llms.txt) indexes the docs;
[AGENTS.md](AGENTS.md) is for working *on* the code.

## Under the hood, in one line

Command Bus → Context Builder → Policy Engine → Middleware → Executor (tool-loop) →
Event Stream / SSE, checkpointed to SQLite (or memory, for dev). It runs on the
[Async](https://github.com/socketry/async) fiber scheduler under
[Falcon](https://github.com/socketry/falcon): an LLM turn is almost entirely spent
waiting on the provider, so one process carries many concurrent turns on a few
connections instead of a thread per request — the model
[RubyLLM's async guide](https://rubyllm.com/async/) recommends. Full pipeline in
[Architecture](docs/ARCHITECTURE.md).

## Contributing

Bug reports with a reproduction and small, focused PRs are the most useful thing right
now — see [CONTRIBUTING.md](CONTRIBUTING.md) (setup, house rules, `bundle exec rspec`)
and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Vulnerabilities go through
[SECURITY.md](SECURITY.md), never a public issue.

## Status

Pre-release — APIs may still change, nothing is tagged yet
([CHANGELOG.md](CHANGELOG.md)). Licensed **MIT** ([LICENSE](LICENSE)).
