---
title: Context
parent: Core concepts
nav_order: 5
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
| **Fence notice** | system | **99 — pinned** | identity | Fixed instruction to treat contextual material as data; only with `fencing` on. |
| **Skills** | `<available_skills>` | 80 | identity | Level-1 skill list, minus whatever is already eager — see [Skills](SKILLS.md). |
| **Tool search** | `<available_tools>` | 70 | identity | Level-1 list of deferred tools — see [Tools](TOOLS.md). |
| **Skill trigger** | `<active_skill>` | 85 | volatile | Level-2 bodies: the agent's `skills_eager` set, plus the ones whose `triggers:` match the message — see [Skills](SKILLS.md). |
| **Knowledge** | `<knowledge>` | 77 | volatile | Level-1 top-K learned concepts for the turn's message (+ one-hop `[[links]]`), only if `knowledge.retrieve` is on. Cuttable — see [Knowledge](KNOWLEDGE.md). |
| **Memory** | `<memory>` | 75 | volatile | Durable facts + recent notes, only if `memory` is on. Cuttable. |
| **Briefing** | `<briefing>` | 65 | volatile | The session's working state — the *known* fields only. Only if the pack declared `briefing_fields`. Cuttable. |
| **Session** | history | 60–79 | volatile | The running transcript; priority scales with recency. |
| **Request** | `<request_context>` | 40 | volatile | Turn variables + tenant. Most cuttable; sits last. |
| **Briefing (tail)** | `<recitation>` | 95 | volatile | The still-missing list + next step, rendered **after the whole history** as a `user` message — the last thing the model reads before the current message. |

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

### In-session compaction (opt-in, platform Settings)

When enabled (Studio → Settings → General, or the `compaction` settings hash),
the engine summarizes old turns *inside* the session instead of losing them to
eviction:

- **Trigger:** after a turn commits, if the session's *uncompacted* message
  count exceeds `compact_after` (default 40), everything but the last
  `keep_last` messages (default 20) is summarized by a cheap model
  (`compaction.model`, falling back to the platform `utility_model`; neither
  set = the feature is inert and `insika doctor` warns). Runs off the critical
  path — the customer already has the answer.
- **Read path:** the Session provider replaces the compacted prefix with ONE
  history fragment — a `user` message wrapped in `<conversation_summary>` tags,
  priority 59 (one step below the oldest verbatim message), source
  `compaction` (its own category in the context trace). The tail stays
  verbatim and the boundary is **stable** between compactions, so the prompt
  cache holds after it.
- **What survives:** the default prompt orders the summary to preserve customer
  facts (sizes, CEP, order numbers), the assistant's commitments, the still-open
  questions and the decisions already made; on re-compaction the previous
  summary is folded in, so a fact from turn 3 survives every later batch.
  A platform `compaction.prompt` replaces the default wholesale.
- **Scope:** store-sourced history only — a checkpoint resume replays its own
  tape and an explicit `history` is the caller's contract; neither is
  rewritten. Observability: the `:context_compacted` event, the
  `insika.context.compacted` counter and `{upto, runs}` in the context trace.

Compaction does not replace the budget: eviction stays as the hard backstop
for a single oversized turn. Tune `context_budget` and keep the identity lean
regardless.

#### Native Responses compaction

Set `compaction.mode` to `"native"` alongside `enabled: true` to use RubyLLM's
manual compaction endpoint on supported OpenAI, Azure and xAI Responses chats.
The default is `"summary"`, described above. Native mode uses the turn's resolved
model and credential context; `compaction.model`, `prompt` and `utility_model`
do not apply. Unsupported providers remain uncompacted; there is no second
summary request or automatic switch to another provider.

After the turn commits, a fresh chat compacts the stored, filtered prefix.
The original messages remain stored. Opaque state is separate from the spoken
transcript and is replayed only with the same provider, model and protocol.
Fallbacks and protocol changes restore the original prefix. Checkpoints retain
both alternatives. A native marker is also skipped if another context provider
has already supplied history, because Responses would replace that history.

The budget conservatively counts the original prefix as well as the native state,
and can evict this entire unit. This version reduces provider input when that unit
fits; it does not increase local context-budget capacity. Each compaction rebuilds
the whole stored prefix rather than chaining opaque state. Native usage is reported
on `context_compacted`; the opaque payload is not included in that event.

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

### Repairing stored assistant context

An operator may attach a string `context_content` to a stored plain assistant
message. Session replay uses that text while preserving the original `content`
for display and audit. User messages, tool results, assistant tool calls, explicit
history and checkpoint replay ignore this field. Existing compaction summaries
are not rewritten. This is a targeted data repair, not an automatic tool-markup
parser; text is never converted into tool execution.

## Memory

With `memory` enabled, an agent gains a built-in `remember` tool for durable
facts, and those facts (plus recent notes) are injected back into the prompt on
later turns — **including turns in a different session**. Memory is scoped per
`(tenant, customer)` when the message carries a `customer`. Without a customer,
it uses the tenant's cell; without either, it uses the session's marked
`memory:chat:<session id>` cell. A fresh session therefore does not isolate
memory when it still carries the same tenant. This is distinct from *session history*, which is the transcript of one
conversation; memory is the small set of facts that should outlive any single
conversation. Facts and notes are editable from the Studio agent page. See
[`examples/memory/`](https://github.com/guizaols/insika/tree/main/examples/memory/) for a runnable cross-session example.

In Studio, open **Agents → select an agent → Configuration → Memory & knowledge**.
Memory, knowledge learning and knowledge retrieval have separate switches. Each
source has its own optional rerank provider, model, candidate limit and timeout;
reranking is off by default. Disabling rerank keeps memory and knowledge working
with their usual retrieval and clears only that source's rerank configuration.
The memory selection count applies only while memory reranking is on. The knowledge
selection count also applies without reranking. Provider credentials are configured
separately, never in this form. Changes apply to this agent's future turns.

To select a smaller memory block for each message, keep `"memory": true` and add
`"memory_retrieval": {"top_k": 3, "rerank": {"provider": "cohere", "model": "rerank-v3.5", "candidate_limit": 20, "timeout_seconds": 2}}`
to the agent profile or pack. The engine first reads only the current memory cell,
ranks active facts and considers the newest `candidate_limit` notes by word overlap and recency,
then sends at most `candidate_limit` redacted candidates to the configured reranker.
An empty message or reranker failure keeps the usual full facts and ten recent notes.
Older notes outside that read window remain available in the store and Studio, but
cannot be selected for the turn.

Knowledge can use the same opt-in reranker: set `knowledge.retrieve: true`,
`knowledge.top_k: 3`, and `knowledge.rerank` to the `provider`, `model`,
`candidate_limit`, and `timeout_seconds` object above. The Scan index first
finds matching concepts in the agent and tenant scope. The reranker can reorder
only those candidates; a paraphrase with no matching terms still finds nothing.
Knowledge sends the candidate name, description, and body; memory sends the
fact key/value or note text. The built-in PII and secret detector redacts
recognized patterns before transmission, but it cannot recognize every secret.
Use a provider and credentials appropriate for this external text transfer.
Reranker failure keeps lexical knowledge matches or the usual memory block.
The reranker adds a provider call and may add cost; missing provider usage is
reported as unknown, not zero. Keep reranking off until an agent's own live
evaluation shows better answers within its latency and cost budget.

Facts carry **provenance metadata**: every fact record stores `origin`
(who wrote it — `"engine"`, `"operator"`, `"legacy"` or `"distilled"`),
`created_at` / `updated_at` timestamps, and an optional `expires_at` (ISO8601) —
**an expired fact is never injected**, even before the daily sweep prunes it. The
Studio Customers drill reads and edits the same cell the next turn reads (injection
unchanged), and every operator mutation lands in the content-free audit trail
(digests, never values). The sweep honors the `memory_ttl_days` setting on its own
knob — see [Security](SECURITY.md#memory-and-the-right-to-be-forgotten-lgpd).

An **approved distilled fact** (see [Facts](FACTS.md)) lands in the
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

With fields declared, the briefing renders in **two places**, and the split is
deliberate.

The durable half — what is already known — sits in the `:system` context
(priority 65: below identity/skill/memory so it never breaks the cacheable
prefix, above the turn's own `<request_context>`):

```
<briefing>
known:
  size: M
</briefing>
```

The half that is a *goal* — what is still missing and the agreed next step — is
**recited at the tail**, after the whole history, as the last thing the model
reads before the current user message:

```
<recitation>
still missing: budget, delivery_day
next step: send the payment link tomorrow at 10
</recitation>
```

Attention is strongest at the end of the context: a goal stated only at the top
is the first thing a 30-call turn forgets. So the recitation was **moved** there,
not copied — the head never repeats it, and the turn pays for it once. It rides
as a `user` message, like every other engine append inside a turn, so the system
identity prefix stays byte-stable.

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

A stable prefix makes provider caching possible; eligibility, expiry and reported
savings still depend on the provider.

- **Automatic prefix caching** needs no Insika flag. The identity-first render
  order keeps changing memory and request data below the stable prefix.
- **Explicit cache breakpoints** are opt-in via `"prompt_caching": true` on
  the agent profile and applied only when the resolved provider is `anthropic`. With both system layers present,
  Insika sends two text blocks: identity with `cache_control`, then volatile text
  without it. With no volatile text there is one block; with no identity there is
  no breakpoint. Other providers receive a plain system string.

Custom context builders and hooks must keep `system_identity`, `system_volatile`
and their joined `system` consistent. Without a split, or after a hook replaces
only `system`, the chat builder falls back to treating the whole system as identity.
That fallback cannot protect a volatile suffix from cache invalidation.

Cache accounting surfaces as `cached_tokens` (reads) and `cache_creation_tokens`
(writes), visible in telemetry and the Studio tokens chip.

### The two layers

The system block is partitioned into two cache layers:

- **Identity** — bytes that change only on deploy/config edit: the persona
  prompt (`Prompt`), the level-1 skill list (`Skill`) and the deferred-tool
  catalog (`ToolSearch`), the fixed tool-discipline instructions and, when enabled,
  the fencing notice. This is the cacheable prefix.
- **Volatile** — bytes that may change per turn: memory, session history,
  triggered skill bodies, the `<request_context>`. Everything else.

The layer is a **provider-class contract**, not profile data: `ContextProvider`
declares `def layer = :volatile` (conservative — nothing gets pinned by
accident) and the identity providers override to `:identity`. A pack does
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

Each turn, the Executor hashes the rendered identity and tool schemas into
SHA-256 fingerprints and a cumulative `prefix`. The invalidation reason names
the first changed part of that stable prefix. Volatile system categories have
separate diagnostic digests: changes to memory, knowledge or request context do
not report an identity-prefix invalidation. History is excluded.

These fingerprints explain local prompt changes; they do not prove a provider
cache hit. Use the provider's token accounting for that.

The Studio surfaces it in two places: the **session Context card** shows the
turn's cache-hit percentage and the `broke: <category>` line (plus the
`identity` marker on the category rows), and the **agent detail** carries a
cache tab with the per-agent hit series over time. The per-agent series lives
in its own capped store, because a session does not stamp its author — the
per-session trace cannot answer "cache-hit over time for *this* agent".

A stable identity can be reused while the provider cache remains eligible and valid.
A changed tool schema still invalidates the local prefix fingerprint.

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
