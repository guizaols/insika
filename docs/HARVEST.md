---
title: Harvest
parent: Improve
nav_order: 6
permalink: /harvest/
---

# Harvest — skills from real traffic, promoted only if eval AND conversion hold

The harvest is the loop that makes a store smarter with its own traffic: it
reads the store's **finished** conversations, asks a model to propose SKILLS
for the agent's playbook, filters every proposal through two pre-registered
lists (the negative list, the evidence ledger), scores it with a double gate,
and — **only after a human approves** — lands it as a live skill. Nothing is
ever applied automatically, and a skill that fails the gate is terminal: the
same finding must re-surface with new evidence, there is no silent retry.

Per-store data (`harvest:` on the agent), absent = the loop is off for that
agent:

```ruby
harvest enabled: true,
        negative_list: [ { rule: "no-competitor-prices", pattern: "concorrente" } ],
        miner: { model: "deepseek-v4-flash",    # absent = the platform utility_model
                 window: { last_sessions: 200 },
                 max_proposals: 10,
                 budget: { tokens: 100_000 } },
        idle_hours: 24,      # how idle a session must be before it mines
        min_messages: 3      # a shorter session mines noise
```

## The pass

A mine reads ONLY durable, finished data — never an in-flight turn, never a
live prompt prefix (the "fork" is structural: the mining writes nothing to the
sessions it read, so a customer turn's cache is untouched by construction). The
miner gets the transcript slices (masked), the session's evidence-ledger ids,
and the agent's current skill names so it does not re-propose them. Then the
filters, each drop counted and logged:

1. **The negative list** — the versioned rules file (seed, imported
   per store by `insika harvest:negative import --agent ID --file F`) and the
   profile's hot-editable `harvest.negative_list`. A rule is a phrase or a
   regex; phrases match case/accent-folded at word boundaries. Every rejected
   candidate is logged with the rule id.
2. **The grounding filter** — every product reference in a proposal must be
   in the union of the origin sessions' evidence ids (the evidence ledger).
   A store without `grounding.matcher.sku` does not mine at all: product
   claims that cannot be verified are blocked by refusal, not by prompt.
3. **Dedup** — an open `(agent, name)` tuple or a skill the store already has.

## The double gate

A candidate that survives mining is scored by RUNNING it — the eval gate
clones the agent, writes the candidate skill into the clone's agent-scoped
store, enables it on the clone's allowlist, replays the golden set over the
ordinary public surface and compares to the accepted baseline. **Any
regression disqualifies** — the gate is a veto, never a score to argue with.
Judges are mandatory in exactly the shapes the refinement gate already
refuses: no recorded baseline, an all-red baseline, and a judged baseline
replayed with no judge (a rubric'd case with no verdict would count as a
pass, see [Evals](EVALS.md)).

The conversion gate is the second ruler: the store's funnel metric over the
criterion's window, compared to the **frozen baseline** (`freeze_funnel_baseline`). Outcome is evidence — this gate can only say "the
store is measurably worse than the accepted state" or "there is nothing to
compare against". It refuses on missing data, never passes: no frozen
baseline, no criterion, no funnel store, a fold that has not converged — each
named on the Harvest page.

Both passed → the candidate awaits **a human**. Promotion is snapshot-first
(the pre-promotion content + allowlist), then the two existing write commands,
then an append-only log row carrying `skill`, `origin`, `eval_ref`,
`conversion_ref`, `approver`, `snapshot_ref` and the criterion's sha. The
conversion ruler is re-read at the moment the skill lands — a store that
dipped below its frozen baseline since gating parks the promotion with the
current numbers, and a criterion file that changed since boot is a criterion
nobody froze.

## Rollback

One click, deterministic: the snapshot is restored — `WriteSkill` with the
pre-promotion bytes (or `DeleteSkill` when the skill did not exist), the
allowlist restored to the snapshot's set, and the promotion row stamped
`rolled_back_at`. The log stays the single ledger: a skill promoted, rolled
back, re-promoted is three readable rows.

## The honest limits

- **A store with no golden cases cannot gate, and cannot promote.** The gate's
  strength is entirely the golden set.
- **Grounding first.** A store without a matcher does not mine — the product
  loop is blocked until the evidence ledger is live (by refusal, not by
  warning).
- **A promoted skill is live text**, like any skill: the SkillStore's version
  history plus the harvest snapshot plus the log make the rollback path
  deterministic.
- **The first-10 audit is human.** The negative list can carry a false
  restriction (a phrase too broad) — that is exactly the Hermes failure, and
  it is caught by the audit, not by the engine: the list grows and the loop
  stops (`harvest.enabled: false`), both by data.
- **The harvest costs provider money**: one miner call per window plus one
  full golden replay per gated candidate. The `budget` cap, the recorded run
  cost and the manual trigger bound it; the automated loop mines one session
  per claim window.

## The operator surface

- `insika harvest --agent ID [--last-sessions N] [--since ISO] [--full]` — mine one window.
- `insika harvest:negative import --agent ID --file F` — seed the profile's list from a rules file.
- `insika harvest:criterion check --file F` — strict-load the frozen conversion criterion (the hook before any promotion).
- The **Harvest page** in the Studio: the human's inbox (each candidate with
  its evidence excerpt, the eval report, the conversion card, promote/reject),
  the gated-but-blocked rows with the named ruler hole, the pending list, the
  append-only promoted log with the rollback mirror, the negative list with
  per-rule rejection counts, and the criterion block read-only.
