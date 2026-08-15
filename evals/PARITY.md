# PARITY — the pre-registered criterion for the store cut

> **Frozen on:** 2026-08-15, before the first production pair was judged.
> **Applies to:** the shadow experiment defined in RFC-0025.
> **Editing this file invalidates the running window.** Every pair records the
> SHA-256 of this file at the moment it was created; a window whose pairs disagree
> produces `:invalid`, never a verdict. That is the point.

## What is being measured

One **exchange**: a customer message, the reply the incumbent actually sent, and
the reply Insika would have sent for the same message. Not a whole conversation —
each system carried its own history into its own reply, so the comparison is
honest at the exchange level and nowhere else.

A panel of at least three distinct models judges each pair, each model asked twice
with the transcripts swapped (position bias is the known failure of pairwise LLM
judging). A preference that flips with presentation order is recorded as
`comparable`, not as a preference.

## The rule

```yaml
version: 1
unit: exchange
window_days: 7
pairs_per_day: 30
min_decided: 200

min_judge_models: 3
both_orders: true

estimator: wilson_lower_95
win_or_tie_floor: 0.80

worse_rate_ceiling: 0.10
undecided_rate_ceiling: 0.20
incomplete_rate_ceiling: 0.20

per_agent_min_decided: 50
per_agent_win_or_tie_floor: 0.70

human_assisted: report_only
silent: report_only
```

## The verdict, in words

Over **7 consecutive days** with at least **30 pairs each day** and at least
**200 decided pairs** in total, the cut is cleared when:

1. the **lower bound of the 95% Wilson interval** on the win-or-tie rate is
   **≥ 0.80** — the point estimate alone is not enough, because at n≈200 the
   sampling error is about ±5 points and the reading this experiment replaces was
   noise of exactly that size;
2. **no more than 10%** of decided pairs are `worse` — a rate that clears the
   aggregate while serving one customer in seven badly is not parity;
3. **every store** with at least 50 decided pairs is itself at **≥ 0.70**
   win-or-tie. A store blocks its own cut even when the aggregate passes.

The verdict is `insufficient` — not `fail` — while the volume is short. A day with
zero pairs breaks the window; the window restarts rather than skipping the gap.

The verdict is `invalid`, and no rate is computed at all, when:

- the pairs in the window carry more than one hash of this file;
- more than **20%** of judged pairs are `split` or `unknown` (the panel is not
  deciding, so it is not measuring);
- more than **20%** of pairs never got both halves (the mirror contract is broken —
  RFC-0025 E2's own discard condition).

## What is counted but never scored

- **`human-assisted` pairs** — the incumbent's half contains text a person typed.
  Comparing a model to a person and calling it a win is a lie in both directions.
  Reported separately, excluded from every rate.
- **`silent` pairs** — Insika published nothing because a tool delivered out of
  band (`halt_when`). The eval sees only what we publish and cannot tell that from
  an agent that said nothing (RFC-0014 §7). Reported, excluded, and if the silent
  rate is large the pairwise reading is not the right instrument for that store.

## Why these numbers

| Number | Why |
|--------|-----|
| `window_days: 7` | A week covers the weekday/weekend mix of a retail store. Shorter reads one traffic shape; longer delays the cut for no extra confidence at this N. |
| `pairs_per_day: 30` | The daily floor exists to stop a good afternoon from becoming a verdict. 30 × 7 ≈ 210 ≥ `min_decided`, so volume and duration bind at roughly the same point. |
| `min_decided: 200` | At n=200 the Wilson half-width is ≈5 points. Below ~150 the interval is too wide for an 0.80 floor to mean anything; above ~400 the extra confidence costs days. |
| `win_or_tie_floor: 0.80` | Non-inferiority, not superiority: the incumbent answers 403k chats and the bar is "does not serve customers worse", so ties count as wins and one in five may be worse. |
| `worse_rate_ceiling: 0.10` | The floor above can be met with 20% `worse` and 0% `better`. This says the tail matters on its own. |
| `per_agent_win_or_tie_floor: 0.70` | Looser than the aggregate on purpose: a per-store slice of ~50 pairs has a ±13 point interval, so a stricter per-store bar would mostly measure noise. It is a **blocker for an obviously bad store**, not a second parity test. |
| `min_judge_models: 3` | Two models cannot produce a majority; three make `split` a real outcome instead of a tie. |
| `undecided_rate_ceiling: 0.20` | Above this the panel is the thing being measured. |
| `incomplete_rate_ceiling: 0.20` | RFC-0025 E2's discard condition, restated as a rule the fold applies. |

## What this criterion does NOT decide

It does not gate the pre-merge suite, and no baseline reads it. "Worse than the
incumbent" is an answer about a replacement decision, not a suite regression
(RFC-0014 §3.4). Reaching the threshold clears **H-paridade** and unblocks 0.5/0.6;
not reaching it means those do not start.
