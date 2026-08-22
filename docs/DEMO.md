---
title: Demo data
parent: Operate & prove it
nav_order: 10
permalink: /demo/
---

# Demo data — see every loop working at once

Most of what makes Insika worth looking at only shows up after data has
accumulated: a [funnel](AGENTS.md#the-outcome-funnel-rfc-0032) with a frozen
baseline needs weeks of folded outcomes, a [refinement](REFINEMENT.md)
proposal needs a run that actually found something, an
[approval](AGENTS.md#layer-2-policies-and-approvals) needs a tool call
someone is waiting on. A fresh instance shows none of that — every one of
those pages renders its empty state, which makes it hard to tell "nothing
happened yet" from "this doesn't work."

`insika demo:seed` closes that gap in one shot: it provisions a single
fictional agent (`demo-store`, an e-commerce support bot) and writes enough
realistic-looking data to see every loop at once.

## What it creates

| Page | What you'll see |
|------|------------------|
| [Funnel](AGENTS.md#the-outcome-funnel-rfc-0032) — `/studio/funnel?agent=demo-store` | 40 days of folded outcomes (`greeted → browsing → cart_started → checkout_started → purchased`) and a **frozen baseline** |
| [Follow-ups](AGENTS.md#follow-ups--the-seller-who-comes-back-rfc-0033) — `/studio/followups?agent=demo-store` | one record in each state: `pending`, `fired` (one per arm, so the A/B card has something to compare), `cancelled`, `blocked` |
| [Refinement](REFINEMENT.md) — `/studio/refinement?agent=demo-store` | four runs across the lifecycle: `awaiting_approval`, `applied`, `rejected` (gate failed), `no_findings` |
| [Approvals](AGENTS.md#layer-2-policies-and-approvals) — `/studio/approvals` | two pending tool calls waiting on a human, one already resolved |
| [Facts](FACTS.md) — `/studio/facts` | three distillation proposals (`pending`, `approved` — with the resulting memory fact, `rejected`) |
| [Evals](EVALS.md) — `/studio/evals?agent=demo-store` | six golden cases and a baseline run with a mix of passes and one failure |

Every record is written through the same store APIs a real turn would use
(`OutcomeStore#create` + the funnel fold, `FollowupStore#create` + its
transitions, and so on) — there is no bulk-insert shortcut, and no bundled
`.rb` script outside `lib/` (nothing here needs a checkout; it ships in the
gem).

## Running it

From the CLI, against whichever store the rest of your commands already use
([Running locally](RUNNING-LOCAL.md#variables-all-optional) — `INSIKA_DB`
unset means an ephemeral, in-memory store, which is a fine place to try this):

```bash
insika demo:seed
```

A second run is a safe no-op once `demo-store` exists; pass `--force` to seed
another batch on top (the funnel baseline recomputes cleanly, but follow-ups,
refinement runs, approvals, proposals and goldens accumulate rather than
reset — none of those stores expose a per-agent bulk-delete that a shared
"platform" tenant could call without risking another agent's data).

From the Studio, open **Settings → Demo data** and click **Seed demo data**.
It dispatches the exact same command the CLI runs — the Studio never writes a
store directly, here or anywhere else.

**This writes into whatever store the running instance already has open.**
There's no separate demo database and no isolation: point `INSIKA_DB` at a
scratch file (or leave it unset, for an ephemeral store) before seeding —
never at a deployment holding real tenant data.

## Then look around

Once seeded, the CLI prints the same six paths listed above. If Studio isn't
running yet, boot it the way you already do — see [Running
locally](RUNNING-LOCAL.md#boot) for a checkout, or [Embedding](EMBEDDING.md)
for `Insika.agent { … }.serve` — pointed at the same `INSIKA_DB`. Studio reads
every agent's profile from the same config store, so it will show
`demo-store` next to whatever agent you're actually building, no matter which
one the running process itself defines.

## See also

- [Refinement](REFINEMENT.md), [Facts](FACTS.md), [Evals](EVALS.md) — what
  each seeded page actually means.
- [Running locally](RUNNING-LOCAL.md) — booting Studio against a durable
  `INSIKA_DB`.
