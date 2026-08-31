---
title: Limits and policy
parent: Core concepts
nav_order: 2
permalink: /policy/
---

# Limits and policy

What an agent may do is layered. Each layer is independent, opt-in where it
matters, and editable hot — the same profile keys covered in [Agents](AGENTS.md),
grouped here because they answer one question: what is this agent allowed to do,
and what stops it when it tries to do more.

What an agent may do is layered. Each layer is independent, opt-in where it
matters, and editable hot.

## Layer 1: Tools (what it can call)

`tools_allow` / `tools_deny` / `tools_allow_groups` decide which tools enter the
turn's tool-loop, enforced by the builtin `tool_allowlist` policy — which the
engine adds for you the moment any of the three is declared, so you never have to
name it in `policies` (see [Agents](AGENTS.md#the-allowlist-convention)). See
[Tools](TOOLS.md) for how tools are defined and registered, and
[`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/).

## Layer 2: Policies and approvals

Policies are named entries evaluated before the turn runs. **Only the policies a
profile names run** — which is why `tool_allowlist` is added implicitly by a
declared tool list; an allowlist nobody applies is worse than no allowlist.
Builtins cover tool-, skill-, and workflow-allowlisting, plus
**`ApprovalRequired`** — which
does not allow or deny but *tags* a tool as needing human approval. Set
`approvals_required: [tool names]`; the gate then fires when the model tries to
call that tool, suspending the turn until an operator approves it in the Studio.
See [Security](SECURITY.md#human-approval).

## Layer 3: Guardrails (content safety)

`guardrails` configures input/output content safety per agent — **opt-in**, so an
agent that says nothing gets a conservative default (deterministic detectors on,
LLM moderator off). See [Security](SECURITY.md#guardrails) and
[`examples/guardrails/`](https://github.com/guizaols/insika/tree/main/examples/guardrails/).

## Layer 4: Edge limits (flood and spend control)

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

### Calendar budgets — the daily/monthly cost wall

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

### Reliability — retries, fallback, circuit breaker

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

### Intent routing — classify before you answer

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
  outcome](AGENTS.md#the-stuck-signal--i-cannot-proceed) and the route's `message`
  (or description) as the lead-in — the consumer interprets it. A route with
  neither is just a label. A delegation counts against the same delegation
  depth cap as a subagent (`INSIKA_SUBAGENT_DEPTH_CAP`, default 5), so a pair
  of agents routing to each other stops instead of looping.

Absent `routes` = no classification, no extra call, byte-identical turn.

### Operator alerts — the webhook

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

## Layer 5: Reasoning (thinking)

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

## See also

- [Agents](AGENTS.md) — the profile these keys live on.
- [Tools](TOOLS.md) — how a tool gets defined, registered and allowed.
- [Security](SECURITY.md) — the deployment-side counterpart: sandbox, egress, secrets.
