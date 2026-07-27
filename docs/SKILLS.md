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

The Level-1 list is budgeted like any other context fragment
(see [Context](CONTEXT.md)); the Level-2 body only costs tokens on the turns that
open it.

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
- [`examples/skills/`](https://github.com/guizaols/insika/tree/main/examples/skills/) — progressive loading, runnable.
