---
title: Agents
parent: Build an agent
nav_order: 1
permalink: /agents/
---

# Agents

An **agent** is the unit you configure and address. It is an immutable
`AgentProfile` value object — an identity (the system prompt), a model, and a set
of layered access controls — stored as a row in SQLite. Everything about an agent
is **data**: created and edited at runtime through the DSL, the API, or the
Studio, and every edit is **hot** — no restart, no redeploy. An in-flight turn
keeps the profile it captured when it started; the next turn sees the new one.

> Smallest possible agent — see [`examples/hello-agent/`](https://github.com/guizaols/insika/tree/main/examples/hello-agent/):
>
> ```ruby
> agent = Insika.agent("assistant") do
>   model "deepseek-chat"
>   provider :deepseek
>   instructions "You are a concise, friendly assistant."
> end
>
> puts agent.reply("hi")   # => one turn, in-process
> ```

## Three ways to create an agent

All three land on the **same** config-over-code import path — they differ only in
ergonomics, not in what they produce.

- **DSL** — `Insika.agent("id") { … }` builds an agent definition and imports it
  into the durable store. Best for code-defined agents and examples. The DSL
  auto-enables the tool- and skill-allowlist policies. `model` is optional — a nil
  model resolves the platform `default_model` at turn start.
- **API** — `POST /v1/agents` with a definition (a "pack": an agent config plus its
  prompt files, skills, and data-tools). The import is **idempotent** and
  **authoritative** — what leaves the definition leaves the agent, so a
  re-import that drops a tool or skill also removes it. `DELETE /v1/agents/:id`
  removes an agent.
- **Studio** — create and edit an agent by hand in the control UI (Config /
  Prompts / Skills / Memory / History tabs), backed by the same commands.

Creating an agent validates its id (required, must be unique) and its subagent
graph (cycle/depth — see [subagents](#delegation-subagents)) **before**
persisting anything.

### Addressing an agent

Once it exists, an agent is addressable by id as the `model` on the
OpenAI-Responses-compatible endpoint:

```jsonc
POST /v1/responses
{ "model": "<agent-id>", "user": "<session-id>", "stream": true, "input": "hello" }
```

`user` is the session id (see [Context](CONTEXT.md)); `stream: true` streams the
turn as Server-Sent Events.

## The AgentProfile

A profile is built through one front door — `AgentProfile.build(id:, model: nil, …)`.
Its free-form hashes (`params`, `guardrails`, `sandbox`, `metadata`, …) are
normalized to string keys once, at build time; no reader downstream does dual-key
lookups.

### Default limits

```ruby
DEFAULT_LIMITS = {
  turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
  context_budget: 8_000, max_tool_calls: 50, approval_timeout: 3_600
}
```

`build` merges your overrides over these — you set only the deltas.

> ⚠️ **`context_budget` defaults to 8000 tokens.** A large system prompt (a rich
> persona can run tens of thousands of tokens) exceeds it, and a pinned identity
> that overflows the budget fails the turn rather than truncating the identity.
> If a freshly created agent returns empty turns, raise `context_budget` first.
> See [Context](CONTEXT.md).

### The allowlist convention

The same three-state rule governs tools, skills, context providers, and workflows
— learn it once:

- `nil` (or absent) = **all** (opt-in capabilities aside);
- `[]` = **none**;
- `[names]` = **exactly** those.

For tools, a paired deny list (`tools_deny`) **always wins**, and
`tools_allow_groups` unions a per-group allowlist on top of `tools_allow`.

Three capabilities invert the default — `nil`/absent means **OFF**, not "all":
`subagents`, `memory`, and `guardrails` (each defaults to off or a conservative
setting, never "everything on").

## The five access layers

What an agent may do is layered. Each layer is independent, opt-in where it
matters, and editable hot.

### Layer 1: Tools (what it can call)

`tools_allow` / `tools_deny` / `tools_allow_groups` decide which tools enter the
turn's tool-loop, enforced by the tool-allowlist policy. See [Tools](TOOLS.md)
for how tools are defined and registered, and [`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/).

### Layer 2: Policies and approvals

Policies are named entries evaluated before the turn runs. Builtins cover
tool-, skill-, and workflow-allowlisting, plus **`ApprovalRequired`** — which
does not allow or deny but *tags* a tool as needing human approval. Set
`approvals_required: [tool names]`; the gate then fires when the model tries to
call that tool, suspending the turn until an operator approves it in the Studio.
See [Security](SECURITY.md#human-approval).

### Layer 3: Guardrails (content safety)

`guardrails` configures input/output content safety per agent — **opt-in**, so an
agent that says nothing gets a conservative default (deterministic detectors on,
LLM moderator off). See [Security](SECURITY.md#guardrails) and
[`examples/guardrails/`](https://github.com/guizaols/insika/tree/main/examples/guardrails/).

### Layer 4: Edge limits (flood and spend control)

Two independent, opt-in ceilings, enforced *before* the model is ever called:

- **`chat_rate_limit`** — turn attempts per session per `chat_rate_window`.
- **`agent_token_ceiling`** — total tokens per agent per `agent_token_window`.

On breach the turn halts gracefully with a configurable `limit_response` and
**zero LLM calls**. Windows are set at the platform level; the ceilings can be set
per agent (blank inherits the platform value, `0` explicitly disables it).

> ⚠️ The token window default is **86400 (daily)**. To express "500k tokens per
> **hour**", set `agent_token_window = 3600` explicitly. A per-agent key that is
> *present but nil* reads as OFF for that agent — leave the key **absent** to
> inherit. See [Security](SECURITY.md#edge-limits).

### Layer 5: Reasoning (thinking)

Controls the model's thinking budget, resolved by precedence
**Chat > Agent > Model > Global** (first non-blank wins):

| Scope | Where |
|-------|-------|
| Chat | session var `__llm__.thinking` |
| Agent | `profile.params["thinking"]` |
| Model | platform `model_params[<ref>].thinking` |
| Global | platform `thinking` |

Values: `off | on | low | medium | high`. `off`/`on` toggle thinking; the effort
levels map to the provider's thinking-effort parameter. This is a control
primitive, not a latency lever — turning reasoning off does not necessarily speed
up a turn, because most of a turn's latency is the provider itself, not thinking.

## Delegation (subagents)

An agent can delegate to **subagents**: named child agents it may invoke as a
tool, fanning work out and collecting results. Subagents are **opt-in**
(`subagents` defaults to none) and the graph is validated for cycles and depth at
create time. This is off by default because it multiplies model calls — enable it
deliberately. See [`examples/`](https://github.com/guizaols/insika/tree/main/examples/) for the fan-out pattern.

## Where agent data lives

Every agent is a row in one SQLite key-value table (WAL mode), namespaced under
`config:agents`. The database file is `INSIKA_DB`. The profile source reads
**fresh** on each dispatch, which is why Studio and API edits take effect on the
next turn with no restart. See [Deploy](DEPLOY.md) for the durable-volume setup and
[Context](CONTEXT.md#the-volume) for why editing a committed file does *not* change
a running agent.

## See also

- [Tools](TOOLS.md) — define, register, and troubleshoot tools.
- [Skills](SKILLS.md) — progressive playbooks an agent loads on demand.
- [Context](CONTEXT.md) — what fills a turn's prompt, and memory.
- [Security](SECURITY.md) — guardrails, sandbox, approvals, edge limits.
- [Architecture](ARCHITECTURE.md) — how a turn actually runs.
- [`examples/`](https://github.com/guizaols/insika/tree/main/examples/) — one runnable project per capability.
