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
A prompt file is **text**. Passing a structured value where the markdown belongs —
a `{"content": …}` wrapper in a pack, or a store entry read and written back — is
rejected, not coerced: `to_s` on a Hash produces Ruby's `#inspect`, and a prompt made
of that is served on every turn while looking healthy.

Its free-form hashes (`params`, `guardrails`, `sandbox`, `metadata`, …) are
normalized to string keys once, at build time; no reader downstream does dual-key
lookups.

### Default limits

```ruby
DEFAULT_LIMITS = {
  turn_timeout: 300, tool_timeout: 60, provider_timeout: 5,
  context_budget: 8_000, max_tool_calls: 50, approval_timeout: 3_600,
  tool_concurrency: 1
}
```

`build` merges your overrides over these — you set only the deltas.

### `tool_concurrency` — parallel tool calls

When the model asks for several tools in one step, they run **one at a time by
default**. Raise `tool_concurrency` and they run together, capped at that number
in flight:

```ruby
limit :tool_concurrency, 4   # nil / 0 / 1 = serial (the default); N = at most N at once
```

One number is both the switch and the cap. It pays off only when a turn issues
several **slow, independent** calls (data tools waiting on HTTP) — the wall-clock
becomes the slowest call instead of the sum. It buys nothing for fast in-process
tools, and it is the *model* that decides the fan-out, which is why the cap is not
optional: an uncapped batch of 15 data tools is 15 simultaneous requests to the
same backend.

> ⚠️ **It is silently disabled for any turn that has an approval-required tool.**
> The approval wait is one mailbox per task, so two tool calls suspended for an
> operator would deadlock — the turn runs serially instead. The downgrade is
> per *turn*, not per agent (an agent that lists approvals still gets parallelism
> on turns where none of the allowed tools require one), and it emits one
> `provider_warning` event so the lost speedup is never a mystery.

Two behaviours change once it is on — see [Tools](TOOLS.md#parallel-tool-calls):
`max_tool_calls` becomes approximate, and the transcript records tool results in
completion order.

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

### Declaring what this deployment has

`declares "promotions", "human_handoff"` records facts about the deployment that
are not tools. It decides **nothing** at runtime — it exists so an eval case can
say what it needs and be *skipped* where it is absent instead of failing for the
wrong reason (see [Evals](EVALS.md)). A flat list you write: inferring "this store
has promotions" from data is how a test suite starts lying.

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

## Refinement

`refinement` configures how an agent's own traffic is read back as a report — what
broke, how often, in which conversations. Unlike the layers above it grants
nothing: a run calls no model and edits nothing, so it needs no opt-in and an
absent key still reports. See [Refinement](REFINEMENT.md).

```ruby
refine window: { last_sessions: 200 }, max_findings: 20
```

## Delegation (subagents)

An agent can delegate to **subagents**: named child agents it may invoke as a
tool, fanning work out and collecting results. Subagents are **opt-in**
(`subagents` defaults to none) and the graph is validated for cycles and depth at
create time. This is off by default because it multiplies model calls — enable it
deliberately.

Delegation only means something when the children are resolvable in the same
graph, which is what `Insika.system` is for — several agents, one runtime:

```ruby
system = Insika.system do
  agent("security")    { instructions "Review code for security issues." }
  agent("performance") { instructions "Review code for performance issues." }

  agent "reviewer" do
    instructions "Delegate to the specialists, then synthesize their reports."
    subagents "security", "performance"
  end
end

system.reply("reviewer", code)   # one turn; the parent fans out and synthesizes
system.serve                     # all three on /studio + /v1 (each id is a `model`)
```

When the *shape* of the work is known in advance — draft then edit, classify then
answer, three reviewers then a summary — put the choice in Ruby instead: see
[Workflows](WORKFLOWS.md).

The parent gets two system tools: `spawn_subagent` (one child) and
`spawn_subagents` (**N children in parallel**, one combined result — wall-clock
is the slowest child, not the sum, capped by `INSIKA_SUBAGENT_FANOUT_CAP`,
default 8). A child inherits the *environment* (model, thinking) as a default and
**never** inherits capability: its tools, skills and own subagents come from its
own profile.

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
