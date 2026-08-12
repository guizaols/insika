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

## Format

```markdown
---
name: refunds                       # must equal the directory name
description: When and how to process a refund   # the Level-1 trigger text
triggers: [refund, money back]      # optional: deterministic activation (below)
---

<the full playbook body — loaded only on demand>
```

Frontmatter is parsed tolerantly. A skill's canonical name is its directory name,
which the `name:` field must match.

## Progressive loading: two levels

- **Level 1 — metadata only.** A context provider injects an `<available_skills>`
  list (the name + one-line description of every allowed skill) into the system
  prompt, telling the model to load a skill before acting on it. Cheap, and always
  present for allowed skills.
- **Level 2 — the full body.** A built-in `load_skill` tool returns the skill body
  on demand. It enforces the agent's skill allowlist and is wired **automatically**
  whenever the agent has any allowed skills — you do not add it to `tools_allow`.
- **Deterministic activation — `triggers:`.** When the user message contains one
  of the skill's `triggers` (substring, case-insensitive), the body is injected
  for that turn — no model decision, no `load_skill` call. Only matched skills,
  only that turn. Use it for skills that MUST fire on known phrases; model
  loading stays as the fallback for everything else.

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

## Always-on skills: `eager`

A skill that every turn needs — output format, the marker vocabulary, how to
recover from a failed tool — should not depend on the model choosing to load it.
Mark it in the frontmatter and its body is in the prompt on every turn:

```yaml
---
name: recommendation-formatting
description: How to present products after a search…
eager: true
---
```

An eager skill also **leaves level 1**: it is absent from `<available_skills>` and
`load_skill` refuses to serve it. There is no level 2 left to fetch, and a catalog
pointing at a body already in the prompt only invites a call that pays for a
duplicate.

For the blanket case — a corpus small enough that every body fits — the agent can
opt in to all of them at once:

```ruby
Insika.agent("consultant") do
  skills_eager             # every allowed skill's body, every turn
end
```

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

## See also

- [Context](CONTEXT.md) — how the skills list is budgeted into a turn.
- [Agents](AGENTS.md) — the skills allowlist.
- [Tools](TOOLS.md) — `load_skill` and deferred-tool progressive disclosure.
- [Plugins](PLUGINS.md) — shipping skills inside a plugin, and the two extension tiers.
- [`examples/skills/`](https://github.com/guizaols/insika/tree/main/examples/skills/) — progressive loading, runnable.
