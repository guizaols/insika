---
title: Context
parent: Build an agent
nav_order: 4
permalink: /context/
---

# Context

Every turn, the **Context Builder** assembles the model's prompt from a fixed set
of **providers**, estimates its token cost, and evicts the lowest-priority
non-pinned fragments to fit the agent's `context_budget`. The Executor never
builds the prompt itself — it receives a finished context package. Providers run
in parallel, each with a short per-provider timeout, and an *optional* provider
that fails or times out is dropped with a warning rather than failing the turn.

## What enters a turn's prompt

Providers are chosen by a double gate (the provider opts in for the profile **and**
the agent's `context_providers` allowlist permits it), then assembled by priority
into a deterministic prompt:

| Provider | Block | Priority | Layer | Notes |
|----------|-------|:--------:|-------|-------|
| **Identity** | system | **100 — pinned** | identity | The agent's prompt files (global system files first). Never cut. |
| **Skills** | `<available_skills>` | 80 | identity | Level-1 skill list, minus whatever is already eager — see [Skills](SKILLS.md). |
| **Tool search** | `<available_tools>` | 70 | identity | Level-1 list of deferred tools — see [Tools](TOOLS.md). |
| **Skill trigger** | `<active_skill>` | 85 | volatile | Level-2 bodies: the agent's `skills_eager` set, plus the ones whose `triggers:` match the message — see [Skills](SKILLS.md). |
| **Knowledge** | `<knowledge>` | 77 | volatile | Level-1 top-K learned concepts for the turn's message (+ one-hop `[[links]]`), only if `knowledge.retrieve` is on. Cuttable — see [Knowledge](KNOWLEDGE.md). |
| **Memory** | `<memory>` | 75 | volatile | Durable facts + recent notes, only if `memory` is on. Cuttable. |
| **Briefing** | `<briefing>` | 65 | volatile | The session's working state (known fields, still-missing list, next step) — only if the pack declared `briefing_fields`. Cuttable. |
| **Session** | history | 60–79 | volatile | The running transcript; priority scales with recency. |
| **Request** | `<request_context>` | 40 | volatile | Turn variables + tenant. Most cuttable; sits last. |

The ordering is deliberate: the render order is **identity layer first, volatile
layer after** — nothing volatile can sit above the cache boundary, whatever its
priority — and within each layer the priority sort above holds. That keeps the
cacheable prefix byte-stable (see the prefix cache below).

## Budget and eviction — the actual "compaction"

- The cap is `profile.limits[:context_budget]`, **default 8000 tokens**.
- To fit the budget, the builder cuts **non-pinned** fragments
  lowest-priority-first (ties broken by oldest history first). Under pressure you
  lose request context first, then old history, then briefing, then memory, then
  learned knowledge, then the skill/tool-search level-1 lists — **the pinned
  identity is never truncated**.
- A **pinned** fragment (the identity) that *alone* exceeds the budget raises an
  error — the turn fails rather than shipping a truncated identity.

> ⚠️ **The `context_budget` gotcha.** A rich system prompt can run to tens of
> thousands of tokens — far past the 8000 default. If a newly created agent
> returns empty turns, raise `context_budget` (e.g. to `60000`) before looking
> anywhere else. See [Agents](AGENTS.md#default-limits).

### Compaction is not wired — except the mechanical dedupe

There is a settings stub for LLM-summarization compaction (`enabled: false`,
`keep_last`, a reserved utility-model slot), but **nothing consumes it today**
— and the Studio no longer shows a form for it, so the setting cannot be
switched on by accident. Size is managed purely by hard budget eviction.
Do not rely on compaction to shrink a bloated agent: tune `context_budget` and
keep the identity lean.

One cheap half **is** wired, opt-in per agent: `tool_output_compression` (DSL
`tool_output_compression`, or `"tool_output_compression": true` in the pack).
When on, byte-identical repeated **tool results** in the replayed history
collapse to a compact back-reference (the first occurrence stays full, with a
one-line summary) — no LLM involved. It changes what the model sees, so it is
never a default: an older detail is only in the first occurrence, and a model
that wants it re-calls the tool. Reach for it when a tool keeps returning the
same body (a catalog page, a status) and history is the fragment blowing the
budget first.

> The **Studio session screen** shows what the builder assembled per turn —
> tokens per category (identity, history, memory, …), the tools-schema estimate
> and the budget verdict (`used / cap`, evicted sources). Counts only, never
> fragment content.

## Memory

With `memory` enabled, an agent gains a built-in `remember` tool for durable
facts, and those facts (plus recent notes) are injected back into the prompt on
later turns — **including turns in a different session**. Memory is scoped per
agent, per `(tenant, customer)` when the message carries a `customer`, and per
session otherwise — a session's own memory lives in a marked `memory:chat:<session id>`
cell, never a bare one, so the Customers drill cannot read a conversation as a
customer. This is distinct from *session history*, which is the transcript of one
conversation; memory is the small set of facts that should outlive any single
conversation. Facts and notes are editable from the Studio agent page. See
[`examples/memory/`](https://github.com/guizaols/insika/tree/main/examples/memory/) for a runnable cross-session example.

Facts carry **provenance metadata** (RFC-0031): every fact record stores `origin`
(who wrote it — `"engine"`, `"operator"`, `"legacy"` or `"distilled"`),
`created_at` / `updated_at` timestamps, and an optional `expires_at` (ISO8601) —
**an expired fact is never injected**, even before the daily sweep prunes it. The
Studio Customers drill reads and edits the same cell the next turn reads (injection
unchanged), and every operator mutation lands in the content-free audit trail
(digests, never values). The sweep honors the `memory_ttl_days` setting on its own
knob — see [Security](SECURITY.md#memory-and-the-right-to-be-forgotten-lgpd-rfc-0031).

An **approved distilled fact** (RFC-0034 — see [Facts](FACTS.md)) lands in the
same cell this provider injects, stamped `distilled:<session_ref>` — approved on
the Studio Facts page, never applied automatically.

## Briefing — the session's working state

The **briefing** is the per-conversation working state the agent keeps and asks
for: which facts it already learned (size, budget, delivery day) and the agreed
next step. It is **engine-owned data** — one `"briefing"` key on the session
record, written only by the agent through tools — whose *fields* come from the
pack:

```jsonc
// pack agent.config.json
{ "id": "store-support", "briefing_fields": ["size", "budget", "delivery_day"] }
```

```ruby
# or the DSL — [] = the feature is off (no block, no tools)
briefing_fields "size", "budget", "delivery_day"
```

With fields declared, the turn's `:system` context gains a `<briefing>` block
(priority 65 — below identity/skill/memory so it never breaks the cacheable
prefix, above the turn's own `<request_context>`):

```
<briefing>
known:
  size: M
still missing: budget, delivery_day
next step: send the payment link tomorrow at 10
</briefing>
```

The `still missing` list is the point: the *model* sees which declared fields are
still unanswered, so it stops re-asking for something already given. Stored keys
that the pack no longer declares are never rendered. The Studio session screen
shows the persisted state (known fields + next step), read-only.

The agent writes the briefing through two built-in tools, wired only when the
pack declared fields:

- `update_briefing(field:, value:)` — records a field. An undeclared `field`
  returns an envelope error (`unknown field '…'; declared: …`) and nothing is
  persisted; a blank `value` clears the field.
- `set_next_step(text:)` — records the agreed next step; a blank `text` clears it.

Both are deterministic in-process writes (never enveloped) and survive across
turns and resumes — a resumed conversation re-opens with the briefing intact.

## The provider prefix cache

Two distinct caching mechanisms — don't conflate them:

- **Automatic server-side prefix cache.** Some providers prefix-cache a stable
  system prefix automatically, at no cost to configure. This works **only because**
  the engine renders the system in two layers (below) and the volatile half sits
  **under** the identity boundary, keeping the cacheable prefix byte-stable.
  Anything that injects volatile content high in the system block breaks the cache.
- **Manual cache breakpoints (opt-in).** With `prompt_caching` on **and** a
  provider that supports explicit cache control, the builder sets one cache
  breakpoint at the end of the system block. Only enable this for a byte-stable
  system — a volatile system turns every turn into a paid cache *write*.

Cache accounting surfaces as `cached_tokens` (reads) and `cache_creation_tokens`
(writes), visible in telemetry and the Studio tokens chip.

### The two layers (RFC-0030)

The system block is partitioned into two cache layers:

- **Identity** — bytes that change only on deploy/config edit: the persona
  prompt (`Prompt`), the level-1 skill list (`Skill`) and the deferred-tool
  catalog (`ToolSearch`). This is the cacheable prefix.
- **Volatile** — bytes that may change per turn: memory, session history,
  triggered skill bodies, the `<request_context>`. Everything else.

The layer is a **provider-class contract**, not profile data: `ContextProvider`
declares `def layer = :volatile` (conservative — nothing gets pinned by
accident) and the three identity builtins override to `:identity`. A pack does
not set it — a pack reorganizes *which content goes into the Prompt provider vs
the volatile providers*. The Builder stamps the layer on every fragment at
production, and the render order is **identity first, volatile after** — a
volatile block can never land above the cache boundary, whatever its priority.
Within each partition the existing priority sort is untouched.

The engine's own `doctor` check verifies the declaration: an engine-known
volatile provider (Memory, Session, Request, SkillTrigger) that overrides to
`:identity` is an **error** (guaranteed cache kill); any other custom
`:identity` provider is a **warning** (purity unverifiable from outside — the
output must be byte-stable across turns).

### The observable cache: fingerprints and the invalidation reason

Each turn, the Executor hashes the rendered prefix into a PII-free fingerprint
chain — one SHA-256 per system category in render order, one for the tool
schemas, one cumulative `prefix` — and compares it against the previous turn's
entry. The **invalidation reason** is the first category whose bytes changed (or
vanished); a turn whose prefix held reports nothing. History is deliberately
excluded: a new user message is a divergence every turn, which would be noise,
not a reason.

The Studio surfaces it in two places: the **session Context card** shows the
turn's cache-hit percentage and the `broke: <category>` line (plus the
`identity` marker on the category rows), and the **agent detail** carries a
cache tab with the per-agent hit series over time. The per-agent series lives
in its own capped store, because a session does not stamp its author — the
per-session trace cannot answer "cache-hit over time for *this* agent".

With the prefix stable by construction, the existing `prompt_caching` breakpoint
sits on bytes that stay put — the first (write) turn of a deployment pays the
cache write once, every subsequent turn reads.

## The volume

Agents, prompts, skills, and tools are **data in SQLite**, not files on a volume.
A deploy swaps the image but does **not** rewrite the database — so changing a
committed file changes nothing on a running box. Updates happen at runtime through
the Studio, the API, or the DSL. The durable volume persists only the database
(with optional continuous replication — see [Deploy](DEPLOY.md)). This is why the
instinct to "commit a file and redeploy" fails for agents, skills, and tools alike.

## See also

- [Agents](AGENTS.md) — `context_budget` and the other limits.
- [Skills](SKILLS.md) — how the `<available_skills>` list is built and budgeted.
- [Tools](TOOLS.md) — deferred tools and `tool_search`.
- [Architecture](ARCHITECTURE.md) — where the Context Builder sits in a turn.
