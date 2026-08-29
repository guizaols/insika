---
title: Agents
parent: Core concepts
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
  Prompts / Skills / Memory / Outcomes / Cache / History / **loops** tabs), backed by the same commands.

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
`model`/`provider` are a straight pass-through to [RubyLLM](https://rubyllm.com) — Insika
keeps no allowlist of "supported" models. Whatever RubyLLM's installed version
reaches, an agent can name: today that's 13 provider adapters (Anthropic, OpenAI,
Gemini, DeepSeek, Bedrock, Vertex AI, Azure, Mistral, xAI, OpenRouter,
Perplexity, Ollama, GPUStack) and every model each one exposes — see
[rubyllm.com/available-models](https://rubyllm.com/available-models/) for the
current, live catalog. Upgrading the `ruby_llm` gem is the only thing that ever
widens this list; no Insika code changes with it.

Wire a provider's credentials once in the Studio's **Settings → LLM providers**
(or `POST /v1/settings`) — `api` is any slug RubyLLM recognizes, and
`LLMConfigurator` applies it by reflection (`<api>_api_key=`, `<api>_api_base=`),
so a provider RubyLLM doesn't expose an accessor for is skipped, never a hard
error. To *restrict* which models an agent may use — the opposite direction —
declare `model_policy: { allow: [refs] }` on its profile (exact `"provider/model"`
refs or a `"provider/*"` wildcard); absent means no fence, every configured
model is fair game.
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

### `tool_persistence` — don't give up on the first empty result

The loop guard's mirror image. `max_tool_repeat` stops the model from repeating
the *same* call; `tool_persistence` stops it from giving up after *one* weak
call. When ON (the default), the engine appends a short **"Tool discipline"**
block after the agent's identity in the system prompt: a weak or empty tool
result means *try again with a different approach — a rephrased query, a
synonym, a broader term — before telling the user you found nothing* (and don't
narrate the retries); a tool error means *read it and fix the arguments*, never
repeat the exact same call. Without it, a search that returns 0 results reads as
final and the model answers "I couldn't find it" when a synonym one call away
would have.

This is the **one default-ON profile flag** — every field above is opt-in, this
one is opt-out, because the behavior is the proven default and the exception is
the thing worth declaring:

```ruby
tool_persistence false   # remove the block for this agent
```

The block is a byte-stable constant, so `prompt_caching` stays effective: the
deploy that introduces it costs one cache write per agent, and every turn after
that hits as before.

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

> **`steer` also collects at the door.** The two windows are the same policy's
> halves, not two modes: a `steer` agent that set a `debounce_ms` also merges the
> fragments that land before the turn starts. The window value is what
> an operator replaces the legacy pre-batch buffer with — `steer` catches anything
> that arrives after the turn started, the door window the fragments before it.

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
off by default because it changes what the model sees. And one flag inverts the
other way: `tool_persistence` is **ON unless you set it to `false`** (see
[`tool_persistence`](#tool_persistence--dont-give-up-on-the-first-empty-result)).

### Declaring what this deployment has

`declares "promotions", "human_handoff"` records facts about the deployment that
are not tools. It decides **nothing** at runtime — it exists so an eval case can
say what it needs and be *skipped* where it is absent instead of failing for the
wrong reason (see [Evals](EVALS.md)). A flat list you write: inferring "this store
has promotions" from data is how a test suite starts lying.

## The five access layers

What an agent may do is layered: which tools it may call, which calls need a human, content safety, edge limits on flood and spend, and how much it may think. See [Limits and policy](POLICY.md).

## The stuck signal — "I cannot proceed"

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

## Distillation of customer facts

`distill` configures how finished, idle customer conversations are read back as
proposed facts — the human-gated loop documented in [Facts](FACTS.md). Pack
data, `refinement:`'s shape, and absent = off for that agent:

```ruby
distill enabled: true,
        idle_hours: 6,      # how idle a session must be before it distills
        min_messages: 3,    # a shorter session distills noise
        max_proposals: 10   # cap per session pass
        # prompt: "<what counts as a fact for THIS store>" (the forge's half)
        # model:  "<ref — absent = the platform utility_model>"
```

Nothing is ever applied automatically: the engine writes **proposals**, the
operator approves/rejects/dismisses them on the Studio **Facts** page (the
latch: a dismissed or rejected tuple is never proposed again), and an approval
writes the fact to the customer's memory cell stamped
`distilled:<session_ref>` through an optimistic CAS — an approval never
silently overwrites an operator edit. Sessions are the only candidates, and
the distiller rides the platform `utility_model`, never a new model slot.

## Harvest of skills from real traffic

`harvest` configures how finished, idle conversations are read back as
proposed **SKILLS** for the agent's playbook — the human-gated loop documented
in [Harvest](HARVEST.md). Pack data, `distill:`'s shape, and absent = off for
that agent:

```ruby
harvest enabled: true,
        negative_list: [ { rule: "no-competitor-prices", pattern: "concorrente" } ],
        miner: { model: "deepseek-v4-flash",  # absent = the platform utility_model
                 window: { last_sessions: 200 } },
        idle_hours: 24,
        min_messages: 3
        # prompt: "<what a harvestable skill is for THIS store>" (the forge's half)
```

The loop reads only finished traffic (the fork is structural — the mining
writes nothing to the sessions it read), filters every proposal through the
negative list and the evidence ledger (product claims must reference IDs the
origin sessions actually saw — an agent without `grounding.matcher.sku` does
not mine at all), scores survivors with a double gate (the eval replay against
the clone's golden set, judges mandatory in three shapes; the
conversion "not worse" check against the frozen funnel baseline), and lands
a skill **only after a human approves** — snapshot-first, append-only
promotion log, deterministic rollback. Nothing is ever applied automatically.

## Knowledge from finished conversations

`knowledge` configures the post-turn learning loop documented in
[Knowledge](KNOWLEDGE.md): after a turn completes, the engine extracts durable
**concepts** — facts, procedures, policies, objections — and persists them for
the agent, separate from any one customer's memory. Pack data, `distill:`'s
shape, and absent = off for that agent:

```ruby
knowledge extract: true,
          types: %w[fact policy objection]  # what the extractor may emit
          # prompt: "<what counts as a concept for THIS store>" (the forge's half)
          # model:  "<ref — absent = the platform utility_model>"
```

The model proposes `name`/`description`/`type`/`body`; the engine stamps
`provenance`/`confidence`/`sources`/timestamps itself (a model-authored one
of those is dropped, never trusted) and redacts the body for PII. Writing a
concept name that already exists never blindly overwrites: the engine
decides same claim (bump the evidence), related claim (merge, one extra
model call), or contradicting claim (never merged — appended under a
heading, confidence drops, a human resolves it in the Studio's Knowledge
page). Nothing is injected into a turn's prompt yet — see
[Knowledge](KNOWLEDGE.md#whats-not-here-yet) for what's not here.

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

## Media

Photos, voice notes and documents travel through the message contract as additive content parts, and the engine can hand generated images back the same way. See [Media](MEDIA.md).

## Customer-scoped memory and the right to be forgotten

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
  purges the customer's memory cell, their sessions and everything those
  sessions left behind — per-session traces, the tasks (the message text lives
  in the persisted command), their checkpoints (the transcript) and the outbox
  deliveries (the answer as it was handed to the channel) — and nothing else's:
  `{ "customer": "c-123", "tenant": "acme" }`. **Name the tenant**: the
  operator credential carries none, and without one the purge means the whole
  deployment (the untagged memory cell, plus that customer's sessions in every
  tenant) — right for a single-tenant deployment, never what a multi-tenant
  operator means. Facts also support an optimistic CAS write
  (`replace_if_revision`) for an integration that must not clobber a concurrent
  edit.
- **Tenant deletion** — `POST /v1/commands/delete_tenant_data` (operator)
  purges EVERYTHING the engine holds about one tenant: its sessions and their
  whole footprint (traces, tasks, checkpoints, outbox deliveries), every memory
  cell under the tenant (its own + the customer cells — enumerated from the
  store, so even a cell whose session was already deleted goes), its outcome
  records and its artifacts (a report is content, never kept behind an
  offboarded tenant): `{ "tenant": "acme" }`. Its API tokens are **revoked
  first** (before the sweep): an offboarded tenant whose credentials still
  resolved kept authenticating and could open a new session over the erasure.
  The tenant string is the isolation boundary; a neighbour is untouched.
- **Retention** — the age-based counterpart, as data: the settings key
  `retention_days` (Integer days; absent/0 = OFF, the engine never sweeps by
  default). The tick's daily sweep (at most once per 24 h, behind the same
  single-key claim the stale-task sweep uses) purges sessions (+traces),
  terminal tasks (+checkpoints), delivered/failed outbox records, memory
  facts/notes and outcomes older than the window. A non-terminal task is never
  touched — the Recovery sweep owns those lives — and neither is a delivery
  still owed to somebody. One thing the same daily pass sweeps **regardless of
  `retention_days`**: the budget counter cells whose window already rolled over
  (and their once-per-window alert markers). Those are engine bookkeeping, not
  customer content, and nothing else ever collected them. Artifacts (reports)
  likewise expire on their **own** knob, `artifact_ttl_days` (settings; absent
  = OFF) — the guarantee that PII inside a report dies even in a deployment
  that keeps its conversations forever. See [Artifacts](ARTIFACTS.md).

## Outcomes and follow-ups

What the agent's traffic was worth in business terms, and the tool that lets it come back later on a promise it made. See [Outcomes and follow-ups](OUTCOMES.md).

## Schedules — recurring turns the engine fires

The operator's counterpart to follow-ups: a turn **nobody sends** — the daily
report at 22:00, the eval sweep every night. Declared per agent as pack data
(`schedule "daily_report", cron: …, tz: …, message: …` or `every: N`), edited
hot in the Studio's Schedules config group, fired by the engine's own tick
one turn per claim window, never queued, no catch-up after a downtime (each
missed window is a recorded skip, visible in the Studio):

```ruby
agent = Insika.agent("reporter") do
  schedule "daily_report", cron: "0 22 * * *", tz: "America/Sao_Paulo",
           message: "Run the daily report now.",
           overrides: { turn_timeout: 900, max_tool_calls: 200 }
end
```

The run is a first-class turn stamped `origin: "scheduled"`; `session_mode:
"new"` gives it a fresh session per run (the report shape), `"fixed"` a
standing one; per-run `overrides` raise the chat-time ceilings a report needs.
A hard calendar budget at its cap skips instead of burning the store's tokens.
Distinct by shape and by law from the follow-up tool. See
[Schedules](SCHEDULING.md).

## Artifacts — a report the agent can hand you a URL to

A scheduled report's natural output is not a message but a page — tables,
sections, inline charts. The `save_artifact` tool (a registry tool, in the
agent's `tools_allow`) gives the agent a durable destination: it hands in
title + content and gets a URL back, which it can include in a channel message
("today's report: <url>"). The report is stored (one per run, the listing is
the history), served under `/studio/artifacts/…` inside a sandboxed iframe,
optionally shared outside the Studio via an expiring signed link
(`INSIKA_ARTIFACT_SIGNING_KEY`). The tenant binding is inherited from the
saving agent — never a parameter the model types. Artifact content is LLM
output and is served as untrusted. See [Artifacts](ARTIFACTS.md).

## See also

- [Tools](TOOLS.md) — define, register, and troubleshoot tools.
- [Artifacts](ARTIFACTS.md) — the report destination: the tool, the routes, the signed link.
- [Skills](SKILLS.md) — progressive playbooks an agent loads on demand.
- [Context](CONTEXT.md) — what fills a turn's prompt, and memory.
- [Security](SECURITY.md) — guardrails, sandbox, approvals, edge limits.
- [Architecture](ARCHITECTURE.md) — how a turn actually runs.
- [`examples/`](https://github.com/guizaols/insika/tree/main/examples/) — one runnable project per capability.
