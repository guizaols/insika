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

| Provider | Block | Priority | Notes |
|----------|-------|:--------:|-------|
| **Identity** | system | **100 — pinned** | The agent's prompt files (global system files first). Never cut. |
| **Skill trigger** | `<active_skill>` | 85 | Level-2 bodies: every allowed skill under `skills_eager`, otherwise the ones whose `triggers:` match the message — see [Skills](SKILLS.md). |
| **Skills** | `<available_skills>` | 80 | Level-1 skill list. Off under `skills_eager` — see [Skills](SKILLS.md). |
| **Memory** | `<memory>` | 75 | Durable facts + recent notes, only if `memory` is on. Cuttable. |
| **Tool search** | `<available_tools>` | 70 | Level-1 list of deferred tools — see [Tools](TOOLS.md). |
| **Session** | history | 60–79 | The running transcript; priority scales with recency. |
| **Request** | `<request_context>` | 40 | Turn variables + tenant. Most cuttable; sits last. |

The ordering is deliberate: the **stable identity sits first**, the **volatile
request context sits last**. That keeps the cacheable prefix byte-stable (see the
prefix cache below).

## Budget and eviction — the actual "compaction"

- The cap is `profile.limits[:context_budget]`, **default 8000 tokens**.
- To fit the budget, the builder cuts **non-pinned** fragments
  lowest-priority-first (ties broken by oldest history first). Under pressure you
  lose old history, then the memory block, then request context — **the pinned
  identity is never truncated**.
- A **pinned** fragment (the identity) that *alone* exceeds the budget raises an
  error — the turn fails rather than shipping a truncated identity.

> ⚠️ **The `context_budget` gotcha.** A rich system prompt can run to tens of
> thousands of tokens — far past the 8000 default. If a newly created agent
> returns empty turns, raise `context_budget` (e.g. to `60000`) before looking
> anywhere else. See [Agents](AGENTS.md#default-limits).

### Compaction is not wired

There is a settings stub for LLM-summarization compaction (`enabled: false`,
`keep_last`, a reserved utility-model slot), but **nothing consumes it today**
— and the Studio no longer shows a form for it, so the setting cannot be
switched on by accident. Size is managed purely by hard budget eviction.
Do not rely on compaction to shrink a bloated agent: tune `context_budget` and
keep the identity lean.

> The **Studio session screen** shows what the builder assembled per turn —
> tokens per category (identity, history, memory, …), the tools-schema estimate
> and the budget verdict (`used / cap`, evicted sources). Counts only, never
> fragment content.

## Memory

With `memory` enabled, an agent gains a built-in `remember` tool for durable
facts, and those facts (plus recent notes) are injected back into the prompt on
later turns — **including turns in a different session**. Memory is scoped per
agent. This is distinct from *session history*, which is the transcript of one
conversation; memory is the small set of facts that should outlive any single
conversation. Facts and notes are editable from the Studio agent page. See
[`examples/memory/`](https://github.com/guizaols/insika/tree/main/examples/memory/) for a runnable cross-session example.

## The provider prefix cache

Two distinct caching mechanisms — don't conflate them:

- **Automatic server-side prefix cache.** Some providers prefix-cache a stable
  system prefix automatically, at no cost to configure. This works **only because**
  the identity is at the top of the system block and the volatile
  `<request_context>` is at the bottom, keeping the cacheable prefix byte-stable.
  Anything that injects volatile content high in the system block breaks the cache.
- **Manual cache breakpoints (opt-in).** With `prompt_caching` on **and** a
  provider that supports explicit cache control, the builder sets one cache
  breakpoint at the end of the system block. Only enable this for a byte-stable
  system — a volatile system turns every turn into a paid cache *write*.

Cache accounting surfaces as `cached_tokens` (reads) and `cache_creation_tokens`
(writes), visible in telemetry and the Studio tokens chip.

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
