---
title: Home
nav_order: 1
permalink: /
---

# Insika
{: .fs-9 }

Your agent is the idea. Insika is what holds it up in production.
{: .fs-6 .fw-300 }

[Build your first agent](RUNNING-LOCAL.md){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/guizaols/insika){: .btn .fs-5 .mb-4 .mb-md-0 }

---

*Insika* is Zulu for the pillar that carries a structure — the part nobody admires and
everything rests on. A turn that survives a crash, tools that cannot wander off, limits
that hold under load, and an API your clients already speak. Build the agent; the
scaffolding is already here.

Concretely: a Ruby runtime for **LLM agents in production** — a durable, resumable turn
pipeline behind an **OpenAI-Responses-compatible** HTTP API (`POST /v1/responses`), with
tools, skills, cross-session memory, per-agent policy, content-safety guardrails, and a
web control UI. Point an existing Responses client at it and serve many agents from one
deployment.

## Your first agent

Ruby `>= 3.3` and a provider key (the demo uses DeepSeek). The whole program:

```ruby
require "insika"

assistant = Insika.agent("assistant") do
  model "deepseek-chat"
  provider :deepseek
  instructions "You are Bia, a concise and friendly assistant. Answer briefly."
end

puts assistant.reply("hi, what can you do?")   # one turn, in-process
```

Swap `reply` for `serve` and the same agent is a server — the control UI at `/studio`
plus the drop-in API, on `:9292`. → [Running locally](RUNNING-LOCAL.md)

## Or let your coding agent read the docs

A running instance serves this same documentation as raw markdown, plus a
skill-structured prompt that walks a coding agent through building your first agent:

```
Read http://localhost:9292/start.md then help me build my first agent
```

Alongside it, `GET /models.json` (configured providers, model ids, defaults — no
secrets), `GET /docs` and `GET /docs/<name>.md`. Public and on by default when you
`serve`; opt-in in production (`INSIKA_ONBOARDING=1`).

## Where to go next

- **[Understand the idea](understand.md)** — why a runtime rather than a DIY loop, and how a turn actually runs.
- **[Build an agent](build.md)** — agents, tools, skills, context, and the local loop.
- **[Ship it](ship.md)** — security, confined execution, deployment.
- **[Operate & prove it](operate.md)** — observability, the benchmark, load testing.

Pre-release: APIs may still change and nothing is tagged yet. Licensed MIT.
