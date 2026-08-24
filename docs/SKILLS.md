---
title: Skills
parent: Build an agent
nav_order: 3
permalink: /skills/
---

# Skills

A **skill** is a named playbook an agent loads **on demand**. It is a directory
with a `SKILL.md` file: YAML frontmatter (`name` + `description`) followed by a
Markdown body. The agent always sees the *name and description* of each skill it
is allowed; it pulls the full *body* into context only when a turn actually calls
for it. That is **progressive loading** — an agent can "know" twenty skills exist
while paying for the text of only the ones it opens.

See [`examples/skills/`](https://github.com/guizaols/insika/tree/main/examples/skills/) for a runnable one.

**Skills vs. Knowledge.** They share a format — YAML frontmatter over a
Markdown body, progressive loading — which makes them easy to confuse. A
skill is **curated**: a human writes it, and it is canonical until a human
changes it. A [Knowledge](KNOWLEDGE.md) concept is **learned**: the engine
extracts it from finished conversations, it is `provenance: observed`, and it
sits below skills in the context priority ladder — earned trust, not
authored trust.

## Format

```markdown
---
name: refunds                       # must equal the directory name
description: When and how to process a refund   # the Level-1 trigger text
triggers: [refund, money back]      # optional: deterministic activation (below)
companions: [refund-policy]         # optional: skills this one cannot work without
---

<the full playbook body — loaded only on demand>
```

Frontmatter is parsed tolerantly. A skill's canonical name is its directory name,
which the `name:` field must match.

## Progressive loading: two levels

- **Level 1 — metadata only.** A context provider injects an `<available_skills>`
  list into the system prompt — the name, the one-line description and the
  `triggers:` of every allowed skill — telling the model to load a skill before
  acting on it. Cheap, and always present for allowed skills. **This is the routing
  table, and it is generated:** it cannot disagree with the allowlist, so do not
  hand-write one in a prompt file (see [Drift guards](#drift-guards)).
- **Level 2 — the full body.** A built-in `load_skill` tool returns the skill body
  on demand. It enforces the agent's skill allowlist and is wired **automatically**
  whenever the agent has any allowed skills — you do not add it to `tools_allow`.
- **Deterministic activation — `triggers:`.** When the user message contains one
  of the skill's `triggers`, the body is injected for that turn — no model
  decision, no `load_skill` call. Only matched skills, only that turn. Use it for
  skills that MUST fire on known phrases; model loading stays as the fallback for
  everything else. Matching is on **whole words**, case-insensitive and
  accent-folded: `presente` fires on *um presente* and *presénte*, never inside
  *apresente*.

The Level-1 list is budgeted like any other context fragment
(see [Context](CONTEXT.md)); the Level-2 body only costs tokens on the turns that
open it.

### Only trigger a skill that can finish the turn alone

A `triggers:` match is not a hint — the body lands in the prompt with the
authority of an instruction. So put triggers only on a skill that is
**self-sufficient** for the turn it fires on.

The failure mode is counter-intuitive: injecting a skill that is only *part* of
the answer is **worse than injecting nothing**. Give the model a reference table
whose procedure lives in a companion skill, and it now holds a plausible
half-recipe — so it never calls `load_skill` for the other half, and improvises
the missing part. A precise trigger on the wrong kind of skill still breaks the
turn.

Reference tables, vocabularies and lookup maps are the skills to leave on
level 1. Whole procedures ("run this journey", "recover from this error") are the
ones worth triggering.

## Always-on skills: `skills_eager`

A skill that every turn needs — output format, the marker vocabulary, how to
recover from a failed tool — should not depend on the model choosing to load it.
Name it on the **agent** and its body is in the prompt on every turn:

```ruby
Insika.agent("consultant") do
  skills_eager "recommendation-formatting", "tool-error-recovery"
  # skills_eager        # or: every allowed skill (a corpus that fits the budget)
  # skills_eager false  # or: none — the default
end
```

An eager skill also **leaves level 1**: it is absent from `<available_skills>` and
`load_skill` refuses to serve it. There is no level 2 left to fetch, and a catalog
pointing at a body already in the prompt only invites a call that pays for a
duplicate.

### Why the agent decides, and not the skill

Eagerness used to be an `eager: true` key in the `SKILL.md` frontmatter. That put
the decision on the wrong object: **skills are shared.** `escalation-to-human`,
`recommendation-formatting` and `tool-error-recovery` each sit in several agents'
allowlists, and one flag on the skill forced one decision onto every agent holding
it — with no way to be always-on for the agent that needs it and discretionary for
the one that does not.

`skills_eager` is a per-agent list, so the same shared skill can be both. The
frontmatter key is **ignored** — `insika doctor` flags any skill still carrying it,
and names the agent setting that replaced it.

A name that is not in the agent's `skills` allowlist is a no-op (eagerness is
intersected with what the agent is allowed to see); `doctor` flags that too.

### Keep the discretionary skills on the load path

Making everything eager is a trap, and the reason is not the tokens: **it costs you
the signal**. When every body is present on every turn, "which skills were active"
is always "all of them", and you can no longer tell which one the model reached for.
The `load_skill` call is the only record of that choice — it is a persisted tool
message, so it shows up in the transcript on its own.

So the split is: **eager for what the turn always needs, `load_skill` for what the
turn might need.** The second group is where you want the model's choice on the
record, because that is the group where a wrong choice is worth seeing.

The token trade is real but smaller than it looks: eager bodies sit at a fixed
position ahead of the history, so they belong to the **cacheable prefix**, and they
are still evictable under budget pressure, unlike the pinned identity. Conditional
injection is what breaks that prefix, on exactly the turns it fires.

## Seeing which skills were active, and why

The load path is legible for free: `load_skill` is a tool, so the call is a
persisted message and shows up in the transcript on its own. The deterministic paths
are not a call, so the engine reports them itself — **with a reason per skill**:

| reason | what it means |
|---|---|
| `eager` | the agent's `skills_eager` names it, so every turn gets it |
| `trigger:<phrase>` | this message matched that `triggers:` entry — the phrase as **authored**, so you can find the line to edit |
| `pack` | a plugin's own context provider supplied the body |

Where it shows up, per turn, in the Studio session screen:

- an **activation card in the transcript thread**, placed at the top of its turn and
  in the same visual language as a tool result, so a context-injected skill and a
  model-loaded one read the same way;
- the **Context card**, next to that category's token count, for the after-the-fact
  audit;
- the `skill_activated` **event** (`skills: [{name, reason}]`, `source: "context"`),
  with full task/session correlation.

All three are computed from what actually reached the prompt **after the budget
cut**: a body the budget evicted is reported as an eviction, never as an activation.
A turn that mixes both paths is labelled `mixed`, and each line keeps its own reason.

## Where skills live: the store, over a disk seed

- Skills live as **rows in SQLite** — one row per skill, holding the entire
  `SKILL.md`, versioned (recent revisions are retained).
- On-disk `SKILL.md` files in configured roots are loaded as a **seed**, then the
  store is **overlaid on top — the store wins**. A reload swaps the index
  atomically, so edits take effect **without a restart**.

> ⚠️ **Committing a `.md` file to the repo does not make a skill show up on a
> running deployment.** The on-disk file is only a seed for a *fresh* box; a live
> box serves the store, and a deploy does not rewrite the database. Editing is a
> runtime operation (Studio / API / DSL), not a commit. See
> [Context](CONTEXT.md#the-volume).

## Pairs that must not break: `companions:`

Injecting *part* of an answer is worse than injecting nothing. Give the model a line
map whose query-construction rules live in another skill and it holds a plausible
half-recipe — so it never calls `load_skill` for the other half, and improvises the
missing part. Measured on a real pack: the map arrived by trigger, the rules did not,
and the searches came out malformed. Twice.

Declare the dependency and it travels with whatever brought it — a trigger match, the
agent's eager set, or a `load_skill` call (which returns both bodies in the one call):

```yaml
companions: [query-construction]
```

Two deliberate limits:

- **One level, no transitive walk.** A cycle would be a hang and a chain a budget
  blowout, and "cannot work without" is a direct relationship.
- **Never widens an allowlist.** A companion the agent is not allowed to load is
  simply absent; `insika doctor` flags the declaration instead.

## Specializing a shared skill for one agent

Skills are shared on purpose: `escalation-to-human` belongs in several agents'
allowlists. But sometimes one agent needs a different version of the same skill —
its own return policy, its own store name — and forking it under a second name
throws the sharing away and leaves two things to keep in step.

So the store has a second scope, and resolution is a **precedence chain** with one
more dimension:

```
for agent A, skill <name>:   (A, <name>) in the agent scope,
                             then <name> in the shared scope
```

Three cases fall out of that one rule:

| case | what exists in the store |
|---|---|
| **shared** | only the shared record — every agent gets the same body |
| **override** | both — the agent's wins, for that agent only |
| **agent-private** | only the agent record — invisible elsewhere, and the name may collide freely |

The **name never changes.** An override keeps saying `name: escalation-to-human`
inside, because it *is* that skill, specialized; the allowlist, the `<available_skills>`
list, `load_skill` and the activation card all keep showing the bare name. What
decides which record you get is its **position in the store**, never the frontmatter —
otherwise an override would clobber the shared skill for everybody.

Write one with `agent:`, and remove it the same way (which un-specializes, leaving
the shared skill in place):

```ruby
dispatch(:write_skill,  { name: "escalation-to-human", agent: "store-demo", content: md })
dispatch(:delete_skill, { name: "escalation-to-human", agent: "store-demo" })
```

In the Studio: **Skills → specialize for this agent**, which seeds the override from
the shared body.

## Making a new skill "show up"

For an agent to actually use a skill, **both** conditions must hold:

1. The skill exists as a row in the store (a `SKILL.md` written into it).
2. The skill is in that agent's `skills` allowlist
   (`nil` = all, `[]` = none, `[names]` = those — see
   [Agents](AGENTS.md#the-allowlist-convention)).

Miss either and the skill is invisible: not in the store → nothing to load; not
in the allowlist → the model never sees it in `<available_skills>`.

Two ways to satisfy both:

- **Via a definition/pack import.** The import writes each skill directory into
  the store and sets the agent's `skills` allowlist **authoritatively** from the
  skills present — so a re-import that drops a skill also removes it. Keep the
  definition complete.
- **Directly (Studio / API / DSL).** Write the skill (upserts the row and reloads
  the catalog atomically — live immediately), then attach it to the agent(s) by
  adding its name to the `skills` allowlist.

## Verify it showed up

- In the Studio agent's Skills section, the skill is listed and allowed.
- In a turn, the skill appears in the `<available_skills>` list and the model can
  `load_skill` it (the body loads on demand).
- If the model never mentions it → check the allowlist (condition 2). If
  `load_skill` errors → the store row is missing or misnamed (condition 1); the
  `name:` frontmatter must equal the directory name.

## Drift guards

A skill catalog drifts against the prose that routes to it, and every way it happened
on the pilot was silent — found by reading a customer conversation days later. So the
routing table is **generated** (above), and `insika doctor` reports the residue the
generator cannot remove. Every check takes mechanical inputs only — names, allowlists,
agent identities — because one false positive is enough for an operator to stop
reading the doctor:

| finding | what it means |
|---|---|
| a prompt file names a skill outside that agent's allowlist | leftover hand-written routing: the model is told to use something it cannot load |
| a shared skill's body names one of its own holders | specialized text in shared clothing — the other holders are served that store's policy as their own. Specialize it instead |
| a body references another catalog skill without declaring it a companion | the pair can still arrive apart |
| a declared companion is outside an agent's allowlist | the pair cannot travel for that agent, and the engine will not widen the allowlist |
| a skill still declares `eager:` in its frontmatter | the key is ignored; the decision moved to the agent |
| an agent marks a skill eager that it does not allow | the name is a no-op |

## See also

- [Context](CONTEXT.md) — how the skills list is budgeted into a turn.
- [Agents](AGENTS.md) — the skills allowlist.
- [Tools](TOOLS.md) — `load_skill` and deferred-tool progressive disclosure.
- [Plugins](PLUGINS.md) — shipping skills inside a plugin, and the two extension tiers.
- [Knowledge](KNOWLEDGE.md) — the learned counterpart: engine-extracted concepts, same format, earned trust.
- [`examples/skills/`](https://github.com/guizaols/insika/tree/main/examples/skills/) — progressive loading, runnable.
