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

An optional `"origin"` declares **who wrote the input**. Omit it and it means what
it always meant: a customer typed this. Send `"engine"` when your consumer composed
the message out of context blocks (`<memoria> …`) rather than relaying something a
person said — the transcript then records it, and a report stops counting your own
injected text as the customer repeating themselves. See
[Refinement](REFINEMENT.md#who-wrote-a-message).

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

### Why some limits are missing from that list

`chat_rate_limit`, `agent_token_ceiling`, `queue_mode`, `debounce_ms`,
`debounce_max_ms`, `steer_max_messages` and `steer_join` are real limits, and none
of them appears above. That is the rule, not an oversight:

> **A limit that has a platform-wide layer is absent from `DEFAULT_LIMITS`.**

Those limits resolve **agent → platform (Studio settings) → off**, and the agent
layer wins whenever the key is *present* — including when you set it to `nil` or
`0`, which means *off for this agent*, never *inherit the platform value*. A
default baked into every profile would make the key present on every agent, and
the platform layer would then apply to nobody.

So the two groups read differently on purpose:

| | In `DEFAULT_LIMITS` | Absent |
|---|---|---|
| Examples | `turn_timeout`, `tool_concurrency`, `context_budget` | `chat_rate_limit`, `queue_mode`, `debounce_ms` |
| Absent from your profile means | the constant above | ask the platform, then off |
| You set it to `nil`/`0` | back to the constant | **off**, platform ignored |

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

### `queue_mode` — when a message arrives while the agent is busy

A person on WhatsApp rarely writes one message. They write three:

```
14:02:31  "oi"
14:02:33  "queria saber do pedido"
14:02:36  "1234567"
```

By default each one is a turn, and they run one at a time. So the agent answers
`"oi"` with a greeting the customer has already moved past, and may go looking for
an order before the number arrives three seconds later.

Which mode you want depends on **when** the message arrives:

| `queue_mode` | The message arrives… | What happens |
|---|---|---|
| `followup` (default) | any time | it waits its turn in the queue — today's behavior, named |
| `collect` | before the turn starts | the fragments merge into ONE turn |
| `steer` | while the turn is running tools | it is appended to the run in flight |

#### `collect` — the fragments become one turn

`collect` merges the fragments that land **before the turn starts** into a single
turn:

```ruby
limit :queue_mode, "collect"   # "followup" (the default) = one turn per message
limit :debounce_ms, 2_000      # 0 (the default) = no waiting; N = the quiet window
limit :debounce_max_ms, 10_000 # ceiling on the total wait, so typing forever
                               # cannot postpone the answer forever
```

With those settings the three fragments above become one turn carrying
`"oi\nqueria saber do pedido\n1234567"`, released 2 s after the last one.

All three follow the platform-layer rule above, with one extra rung on top:
**session vars → this agent's limits → the platform default (Studio, `queue.*`) →
off**. Pinning `queue_mode` in a session's vars is how an operator takes one
difficult conversation off `collect` without touching the agent.

> ⚠️ **Your caller has to know it was merged.** When the engine coalesces, only
> one of the three calls owns the reply; the other two answer
> `200 {"task_id": "…", "merged": true}` and stream nothing. A caller that
> delivers a `merged` response anyway sends the same answer to the customer three
> times.
>
> Because of that, `collect` works **only on surfaces that can report the
> verdict**: `POST /v1/messages?stream=false` and channel endpoints. On
> `/v1/responses` and on any open stream it is refused and the agent falls back to
> `followup` — the response body there is fixed by someone else's wire format and
> has nowhere to put the field.

Waiting happens inside the engine, not in your request: the POST is acked
immediately with its `task_id`. Debouncing costs one thing — a customer who sends
a *single* message still waits out the window before their turn starts, which is
why 2 s is a sane value and 10 s is not.

A merged fragment creates no task of its own, so the record that it arrived
separately lives in one event, emitted when the window closes:

```jsonc
{ "type": "turn_coalesced",
  "data": { "task_id": "…", "merged": 3,
            "arrivals": ["2026-08-07T14:02:31Z", "…:33Z", "…:36Z"] } }
```

Times and counts, never content. That is what answers "the customer says they
sent the order number" without keeping a throwaway task per fragment.

#### `steer` — the message arrives while the turn is already running

`collect` only ever touches a turn that has **not started**. Once the agent is
running tools, the customer's next message has nowhere to go but the back of the
queue — so a correction that arrives three seconds into a fifteen-second run is
answered after the run that did not know about it.

`steer` appends it to the run in flight instead:

```ruby
limit :queue_mode, "steer"
limit :steer_max_messages, 5   # how many one run may absorb; the 6th becomes its own turn
limit :steer_join, nil         # nil = the raw text; a template frames it (below)
```

Where it lands is the whole design: **at a tool-batch boundary, appended at the
tail.** After the last result of a batch and before the model's next step — never
between two tool results (Anthropic rejects that outright, OpenAI merely tolerates
it), and never rewriting a message already sent, which is what keeps the prompt
cache valid. So the model sees the correction on its very next step, with the full
context of what it has already found.

Reach for `steer` when turns are long **because they call tools**. If your turns
are one provider round-trip, `collect` is the mode that helps and `steer` has no
boundary to use.

Four cases where the run cannot absorb the message. In every one it becomes the
next turn on the session instead — `followup`, arrived at late, reported as
`turn_steer_released`:

| The run… | Why |
|---|---|
| never calls a tool | there is no batch boundary to append at |
| ends in [`halt_when`](TOOLS.md#halt_when-when-the-answer-is-already-out) | there is no next model step; the message would sit unanswered forever |
| is a [workflow](WORKFLOWS.md) | a workflow orchestrates the model itself and has no chat to append to |
| already absorbed `steer_max_messages` | the bound exists so a tail cannot grow without one |

`steer_join` is for an agent that needs the model to *know* the text arrived
mid-run. It must contain `%{message}`, or the config is refused:

```ruby
limit :steer_join, "the customer just added: %{message}"
```

Default `nil` appends exactly what the person typed — and a steered message is a
first-class transcript message, with no origin, because a person wrote it. The
Studio marks it `steered` in the transcript, derived from its position (a `user`
message right after a tool result); nothing else in the engine puts one there.

> ⚠️ **Same verdict rule as `collect`, different word.** The reply comes out of the
> turn the message joined, so the steered caller is told it does not own it:
> `200 {"task_id": "<the running turn>", "steered": true}`, no stream opened. Only
> surfaces that can carry that verdict may steer — `/v1/messages?stream=false` and
> channel endpoints, never `/v1/responses` or an open stream.
>
> One consequence worth knowing before you turn it on: when the run *cannot* absorb
> the message, the follow-up turn's reply belongs to no caller. It travels the event
> stream like any engine-initiated turn (an async subagent's delivery has the same
> shape). `steer` therefore fits a consumer that reads replies off the stream or off
> a channel delivery — not one that only reads its own POST response.
>
> A steered message also lives **in memory** until a boundary writes it to the
> transcript. A hard stop inside that window loses it; a merged fragment, by
> contrast, is persisted before the window opens.

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

Whether the reasoning ever reaches the **customer** is a separate switch, off by
default:

```ruby
edge_stream thinking: true, intermediate: false
```

`thinking` is the provider's reasoning; `intermediate` is the model narrating its
own tool loop ("let me look that up"). Both are always on the event stream for the
Studio and the trace — this decides only whether `/v1/responses` translates them,
and each opted-in channel gets its own frame type, never the answer's. See
[Architecture](ARCHITECTURE.md#what-crosses-the-edge).

> ⚠️ Turn it on knowing your consumer. One that concatenates every text delta into
> a single message — a WhatsApp adapter — will only be affected once it learns to
> read the new frames, and when it does, the deliberation is what the customer
> reads. That is the operator's call, which is why it is neither a default nor a
> global.

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
