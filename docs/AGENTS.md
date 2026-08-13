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
>   model "deepseek-v4-flash"
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
  context_budget: 8_000, max_tool_calls: 50, max_tool_repeat: 3,
  approval_timeout: 3_600, tool_concurrency: 1
}
```

`build` merges your overrides over these — you set only the deltas.

`max_tool_repeat` is the loop guard: the same tool called with **identical
arguments** that many times in a row gets ONE in-turn warning (a user message at
the next tool-batch boundary: "you already ran this, answer with what you
have"). A repeat after the warning aborts the turn like `max_tool_calls` does.
Set it below 2 to switch it off.

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
| `interrupt` | while a turn is running that is now **wrong** | that turn is abandoned; this message becomes its own turn |

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

#### `interrupt` — the turn in flight is answering the wrong question

`steer` assumes the run is still worth finishing. Sometimes it is not: the customer
says "não, esquece isso" while the agent is three tool calls into the wrong order.

```ruby
limit :queue_mode, "interrupt"   # no other knob: see below
```

The running turn is abandoned and the new message becomes an **ordinary turn** — its
own `task_id`, its own reply. That is why `interrupt` needs no verdict field and works
on **every** surface, `/v1/responses` included: nothing joins anything.

What "abandoned" means, exactly:

- The turn terminates `:cancelled` and **publishes nothing**. The answer to the
  question the customer already replaced never reaches them, and nothing is written to
  the transcript — so what they read and what the session holds still agree.
- **A tool call in flight runs to completion** and its result is recorded on the
  stream. The batch is one unit of work: cancelling the calls that had not started
  would leave it half applied, and fabricating failure results would teach the model
  that tools failed when they did not. The same boundary bounds `turn_timeout`.
- The next turn starts from the last **committed** state. The abandoned attempt is
  visible to an *operator* (its `tool_call`/`tool_result` events and the trace), not to
  the model — a half batch in the history would be an invalid prompt.

> **No grace knob.** An `interrupt_grace_ms` was sketched; it is not
> implemented, and would buy nothing here. The new turn is queued behind the abandoned
> one either way (one turn at a time per session is the invariant), and waiting for a
> boundary inside the request would break the ack-fast rule that put the debounce
> window on the session's fiber in the first place.

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
setting, never "everything on"). `tool_output_compression` is a fourth: opt-in
mechanical dedupe of repeated tool results in the history (see
[Context](CONTEXT.md#compaction-is-not-wired--except-the-mechanical-dedupe)),
off by default because it changes what the model sees.

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

Two independent, opt-in ceilings, enforced *before* the model is ever called —
opt-in everywhere except on a public channel, where `chat_rate_limit` is
[required](CHANNELS.md#a-rate-limit-is-required-not-suggested) and the
[web widget](CHANNELS.md#the-web-widget) refuses to serve without one:

- **`chat_rate_limit`** — turn attempts per session per `chat_rate_window`.
- **`agent_token_ceiling`** — total tokens per agent per `agent_token_window`.

On breach the turn halts gracefully with a configurable `limit_response` and
**zero LLM calls**. Windows are set at the platform level; the ceilings can be set
per agent (blank inherits the platform value, `0` explicitly disables it).

> ⚠️ The token window default is **86400 (daily)**. To express "500k tokens per
> **hour**", set `agent_token_window = 3600` explicitly. A per-agent key that is
> *present but nil* reads as OFF for that agent — leave the key **absent** to
> inherit. See [Security](SECURITY.md#edge-limits).

#### Calendar budgets — the daily/monthly cost wall

A third, opt-in ceiling for the *billing* shape the windows above cannot express:
a spend cap over a CALENDAR day or month, per `(tenant, agent)` when
multi-tenant. Data on the profile (DSL `budget` or the pack's `budget` key):

```ruby
budget daily: 100_000, monthly: 2_000_000, soft: false   # or soft: true
```

- Tokens count the **billed** spend — `input + output + cached + cache_creation`
  (the cached prefix is the bulk of the bill, not an afterthought).
- **Hard** (the default, `soft` absent/false): a turn that arrives with the
  window's spend already at/over the cap **fails** with the typed
  `Insika::BudgetExceeded` — the envelope reads `budget_exceeded` +
  `retry_after` (seconds until the window rolls). It is NOT a customer reply; it
  is an operator signal.
- **Soft** (`soft: true`): the same turn RUNS — crossing the cap emits one
  `budget_warning` event per window and injects a note into the context (the
  model sees it, the transcript does not).
- Either way, crossing `alert_at` (default `0.8` of the cap) fires the same
  warning **before** the wall, once per window.

> ⚠️ Unlike the ceilings above, the cap that counts is per **calendar** window —
> a `daily` budget rolls at UTC midnight, a `monthly` one on the 1st, whatever
> the sun. `agent_token_window` is a fixed seconds window and cannot express
> "the day resets at midnight".

#### Reliability — retries, fallback, circuit breaker (WS3)

The provider interaction is a single attempt by default (RubyLLM's own 2
transport retries aside). For a store that cannot have a dead model take the
chat down, the reliability policy is DATA on the profile:

```ruby
reliability retries: 2, backoff: "exponential",
            fallback: ["openai/gpt-4o-mini"],
            circuit_breaker: { after: 10, within: 60, cooldown: 300 }
```

- **Retries** — transient failures (`:retryable` / `:rate_limited_*` per the
  error classification) retry with exponential backoff, up to `retries`.
  A `:fatal` (auth, billing, bad request) is NEVER retried or rotated. Each
  attempt runs on a fresh chat — the customer-visible answer comes only from
  the attempt that returns.
- **Fallback** — after a node's retries, the turn ROTATES to the next model in
  the chain: the profile's `fallback` refs first, then the platform
  `fallback_models`. The turn's usage is attributed to the model that actually
  spoke (`model_source: "fallback"`).
- **Circuit breaker** — per `(tenant, provider/model)`: `after` failures within
  `within` seconds open the circuit; while open, the turn fail-fasts with the
  typed `circuit_open` + `retry_after` (remaining cooldown) and the provider is
  never touched. After `cooldown` a half-open trial closes the circuit on
  success or reopens it on failure.
- **`timeout`** — per-attempt ceiling (default 30s), counted as a retryable
  failure.

Absent `reliability` = the plain single attempt, byte-for-byte today's
behavior.

#### Intent routing — classify before you answer (WS4)

For a store that must tell "shopping" from "order" from "human" up front,
routing is data on the profile:

```ruby
routes "shopping" => "the customer wants to browse products",
       "order"    => { "description" => "asks about an existing order",
                       "delegate" => "order-agent" },
       "human"    => { "description" => "the customer asks for a person",
                       "stuck" => true, "message" => "A person will help you." },
       "default"  => "shopping",
       "model"    => "deepseek-v4-flash"   # the cheap classifier (absent = the agent's own)
```

- **Classification** — when `routes:` is present, the message is classified into
  one route with the configured model BEFORE the agent chat is assembled, from
  a prompt auto-generated out of the descriptions (no per-route prompt file).
  The route rides the turn: `state.route`, the `:route_classified` event, and
  the terminal event additively.
- **Deterministic default** — the model's answer must be a route name; prose,
  an unknown name, or an empty answer falls back to `default`, never invents.
  A classifier call that FAILS leaves the turn unrouted (routing is additive —
  it must not break the turn).
- **Cost** — the classification is an extra provider call, counted in the
  turn's usage (the trace, the token ceiling and the budget all see it).
- **Actions** — a route value may be a description string, or a Hash:
  `delegate: "<agent-id>"` hands the turn to that existing agent and its
  answer becomes the parent's; `stuck: true` ends the turn with the [stuck
  outcome](#the-stuck-signal--i-cannot-proceed-ws5) and the route's `message`
  (or description) as the lead-in — the consumer interprets it. A route with
  neither is just a label.

Absent `routes` = no classification, no extra call, byte-identical turn.

#### Operator alerts — the webhook (WS6)

Three operational events — `budget_warning`, `breaker_open`, `delivery_failed` —
can be answered per agent with a webhook:

```ruby
alerts webhook: "https://ops.example.com/insika-alerts"
```

When present, each such event is POSTed to the URL as JSON (the event's
type/data/meta, plus the agent). Delivery rides the same outbox + claim +
bounded-retry pipeline as channel answers — at-most-once, crashed deliveries
recovered at boot. The engine transports the event and does not interpret it: a
Slack/CRM adapter is the consumer's. Absent `alerts` = nothing is sent.

Separately, with `INSIKA_TURN_TIMING`, the provider's **live TTFB** is carried in
the streaming envelope: the first content chunk emits an `insika.ttft` frame
(`ttft_ms`) on `/v1/responses`, alongside the per-turn `timing` breakdown on the
final `response.completed`. Additive and opt-in — absent by default.

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

## The stuck signal — "I cannot proceed" (WS5)

The engine doesn't decide what "I can't help you" means — the consumer does. What
the engine provides is the deterministic signal, so that a product wanting
**human escalation** can act on it instead of regexing the answer text:

```ruby
stuck_signal true
```

With `stuck_signal` on, the model may call `signal_stuck(reason:, message:)` when it
determines it cannot proceed (out of scope, missing data, a case a human must take
over). The turn then **ends** — a final message is published (the model's lead-in,
or the tool's `message` when it wrote none) — and the contract carries the signal
twice:

- the terminal event `task_completed` gains an additive sibling
  `"outcome": "stuck"` (and the OpenAI `response.completed` frame too), so a
  consumer that only reads the response can react;
- a dedicated `:turn_stuck` event is published with the `agent`, the `reason`, and
  the final `message` — the subscription point for an operator inbox.

```jsonc
{ "type": "turn_stuck",
  "data": { "agent": "store-support", "reason": "order outside my scope",
            "message": "I'll transfer you to our human team." } }
```

Nothing about handing off, pausing, or resuming is in scope here — escalation is a
consumer concern. How a human joins the conversation is exactly what
`MessageOrigin.operator` ([Refinement](REFINEMENT.md#who-wrote-a-message)) stamps
an imported transcript with; this workstream provides the point at which that
handoff is *triggered*. Off by default (parity): without `stuck_signal`, the tool
is not wired and the outcome never appears.

## Refinement

`refinement` configures how an agent's own traffic is read back as a report — what
broke, how often, in which conversations. Unlike the layers above it grants
nothing: a run calls no model and edits nothing, so it needs no opt-in and an
absent key still reports. See [Refinement](REFINEMENT.md).

```ruby
refine window: { last_sessions: 200 }, max_findings: 20
```

Editing the agent from that report is a separate, explicit `mode` — with a write
allowlist, one or more `proposers`, a token `budget`, and a gate that replays the
golden set before anything reaches a human. All of it is in
[Refinement](REFINEMENT.md); none of it is on until you name it.

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

## Media in the message contract (WS9)

The engine transports media, it never means it. The message accepts additive
**content parts** alongside the text — voice notes and photos travel, and any
skill (a fitting room, an image QA) stays a consumer layer on top:

```bash
curl -X POST /v1/messages?stream=false -H "Authorization: Bearer $TOKEN" \
  -d '{ "agent": "store-support", "session_id": "chat-7",
        "message": "", "parts": [
          { "type": "audio", "url": "https://cdn.example.com/voz.ogg" },
          { "type": "image", "url": "https://cdn.example.com/sofa.jpg" }
        ] }'
```

- **Audio** is transcribed (RubyLLM STT; model via `INSIKA_STT_MODEL`) and the
  text enters the turn marked `source: "voice"` on the terminal event — the
  consumer's signal the person spoke. A consumer that transcribes itself can
  send the text with `"source": "voice"` directly.
- **Images** attach to the model's ask as-is (vision); the provider bills
  them and the usage flows like any ask. Media URLs pass the same egress guard
  (a private/metadata target is refused — SSRF).
- `/v1/responses` accepts the OpenAI multimodal shape: `input` as an array of
  text/image/audio parts.
- **Not here:** TTS and image *generation* as turn outputs (the channel
  declares capability, the envelope carries the media) are the documented
  follow-up half — the engine's input contract is what the fitting-room skill
  builds on.

## Customer-scoped memory and the right to be forgotten (WS8)

Memory is naturally **per customer, not per tenant**. A message that carries a
`customer` key moves the engine's memory scope to that person:

```bash
curl -X POST /v1/messages?stream=false -H "Authorization: Bearer $TOKEN" \
  -d '{ "agent": "store-support", "session_id": "chat-7",
        "customer": "c-123", "message": "cadê meu pedido" }'
```

- **Scope** — with `customer` present, the `remember` tool and the `<memory>`
  block read/write the `[tenant:]customer` cell: two customers under the same
  tenant never see each other, and the `<request_context>` tenant label (the
  merchant) is untouched. Absent `customer` = today's per-tenant/per-chat
  behavior.
- **Right to be forgotten** — `POST /v1/commands/forget_customer` (operator)
  purges the customer's memory cell, their sessions and the per-session traces
  from the engine, nothing else's:
  `{ "customer": "c-123", "tenant": "acme" }`. Facts also support an optimistic
  CAS write (`replace_if_revision`) for an integration that must not clobber a
  concurrent edit.

## Outcomes — business results over real traffic (WS7)

The engine measures what it is told to measure. The operator or the integration
records a conversation's business outcome after the fact — `conversion`,
`escalation`, `deflected`, anything, optionally with a monetary `value`:

```bash
curl -X POST /v1/outcomes -H "Authorization: Bearer $TOKEN" \
  -d '{ "agent": "store-support", "session_id": "chat-7",
        "outcome": "conversion", "value": 129.9 }'
```

The endpoint is **additive and outside the response contract** — the turn never
knows or cares; the engine transports the outcome and never interprets it (what
"conversion" means is yours). Records are tenant-stamped (a tenant principal
writes and reads only its own), and `GET /v1/outcomes?agent=` serves the last
outcome per agent plus the per-day series — the data behind the scorecard card
on the Studio's agent grid.

## See also

- [Tools](TOOLS.md) — define, register, and troubleshoot tools.
- [Skills](SKILLS.md) — progressive playbooks an agent loads on demand.
- [Context](CONTEXT.md) — what fills a turn's prompt, and memory.
- [Security](SECURITY.md) — guardrails, sandbox, approvals, edge limits.
- [Architecture](ARCHITECTURE.md) — how a turn actually runs.
- [`examples/`](https://github.com/guizaols/insika/tree/main/examples/) — one runnable project per capability.
