---
title: Evals
parent: Operate & prove it
nav_order: 4
permalink: /evals/
---

# Evals

An agent has no unit test. The same prompt, the same tools and the same model can give
a different answer twice, so "does it still work?" cannot be answered by asserting on a
string. What you can do is keep a small set of **conversations you care about**, replay
them against a running deployment, and check two different kinds of thing:

- **deterministic** — did it call `search_voucher`? did the reply leak a CPF? did a
  tool error? No model involved, no flakiness, no token cost.
- **subjective** — did it actually resolve the doubt, without inventing a discount?
  That one needs a reader, so a model reads it against a **rubric you write**.

That is the whole idea. The rest of this page is the format, who grades, and how a run
becomes a gate.

## A case is data

```yaml
id: loja-chocolates-cupom
agent: loja-chocolates
turns:
  - user: "tem algum cupom de desconto ativo?"
expect:
  tools_called:
    - search_voucher        # a trailing "?" marks it optional
  must_not:
    - pii_leak
    - tool_error
  rubric: |
    Consults the active coupon with the tool and says what it is — does NOT invent a
    code or a percentage. If there is none, says so kindly.
  min_score: 0.7
```

Turns replay **in order** under one conversation, so a case can build context ("what
about the shipping?" after "I want the 70% bar"); the assertions run on the last turn.

### `policy` — how much the agent should ask before acting

One optional key, because this is the thing a rubric cannot carry alone. Whether the
agent should establish the objective before searching, or act on the first plausible
reading, is a decision **your store** makes — a universal rule would be wrong for half
of them. Declare it and two things happen: a check that costs nothing runs, and the
judge is told the rule instead of guessing it.

```yaml
expect:
  policy: ask_once
```

| policy | the check | the judge is told |
|---|---|---|
| `ask_once` | no reply asks more than one question | two questions in one message is a failure |
| `investigate_first` | turn 1 asks something and calls no tool | ask on a vague request, don't search immediately |
| `act_fast` | turn 1 calls a tool | asking what a search would answer is a failure |

Omit it and only the rubric decides. Unlike the other assertions, a policy is checked
on **every** turn — "one question per reply" is a rule about each reply, and in the
case that motivated this the violation was on the first one.

Question counting is deliberately crude: a run of `?` counts once, and URLs are dropped
so a tracking link's query string is not read as the agent asking something. It is a
policy signal, not grammar — and crude was enough to catch an agent breaking a rule
written in its own prompt, twice, with no model in the loop.

Cases live in two places, and it is the same YAML in both:

- **`evals/golden/**`** in the repo — the curated corpus, reviewable in a pull request,
  and the seed for a fresh deployment.
- **the store** — what a deployment actually runs, editable in **Studio → Evals**
  without a checkout. That matters because the rubric is the part of an eval a domain
  owner can write, and asking them for a git branch means it never gets written.

```bash
insika evals:import              # corpus -> store (a fresh deploy starts here)
insika evals:import --keep-existing   # don't overwrite what was authored in the Studio
insika evals:export --dir /tmp/cases  # store -> YAML, at the paths it came from
```

Export refuses to overwrite an existing corpus unless you pass `--force`: `YAML.dump`
drops the comments those files carry, and each one explains what its case is for.

A case whose stored YAML no longer validates is **listed as broken** on the Evals page
rather than skipped in silence — a test suite that quietly shrinks is worse than a red
one.

## Running

```bash
ADMIN_TOKEN=… ruby evals/run.rb                       # cases from the store, else the corpus
ADMIN_TOKEN=… ruby evals/run.rb --source dir          # ignore the store (no database needed)
ADMIN_TOKEN=… ruby evals/run.rb --agent loja-chocolates --mode both
```

It is **on-demand, not CI**: it costs tokens, needs a live provider key and needs the
target agents provisioned. `--mode perf` reuses the same replay to report TTFB and
total latency over real conversations, so one harness answers both questions.

A run writes `evals/reports/<timestamp>.json` and prints a markdown summary.

## Who grades: a panel, not a voice

The judge reads (conversation, reply, rubric) and returns a score in `[0,1]` with one
sentence of reason. An unparseable judge reply scores **0** — a broken grader must
never look like a pass.

Configure the graders in **Studio → Settings → Evals**, one `provider/model` per line:

| Key | Meaning |
|---|---|
| `judges` | one entry per model. Empty = deterministic assertions only, and rubric'd cases read as `judge_pending` |
| `aggregate` | `median` (default), `mean`, or `min` — how the panel's scores become the one number the report and the baseline read |
| `min_agreement` | fraction of judges that must pass **on their own**. `0.5` = a majority, `1.0` = unanimous |
| `quorum` | samples per judge, on top of the panel |
| `tolerance` | max score drop before it counts as a regression |

Several models is the point. Sampling **one** model three times measures that model's
variance — at temperature 0 it mostly returns the same answer, including the same blind
spot. Two *different* models disagreeing about a rubric is the signal worth having, and
the report keeps each judge's score so a split panel is visible instead of hidden
inside an average.

`--judge-model` still overrides everything for a one-off run.

## The gate

A **baseline** (`evals/baseline.json`) is the accepted state of the corpus. A gated run
blocks only on a **regression** — a case that used to pass and now fails, or a judge
score that dropped past `tolerance` — so known failures don't wedge the gate while a
real drop does:

```bash
ruby evals/run.rb --baseline evals/baseline.json   # exits non-zero on a regression
ruby evals/run.rb --update-baseline                # accept the current state
```

That is what you run before merging a prompt, tool or model change. A case with no
baseline entry never blocks: it shows as failing in the report, but a brand-new case is
not a regression.

## Honest limits

- **A judge is a model.** It has taste and it has bad days; that is why the
  deterministic layer carries the load and the rubric should be objective ("does not
  invent a code" beats "is friendly").
- **A green run is not a proof.** It says the cases you wrote still behave. Cases come
  from real conversations — see [Refinement](REFINEMENT.md) for reading production
  traffic back to find the ones worth adding.
- **The corpus is small on purpose.** Twenty cases covering the hot flows beat two
  hundred nobody curates.

## Where it lives

The harness is `lib/insika/evals/*` — inside the engine, because the refinement gate
needs to score a candidate agent with the same judge, and a second copy of the judge
would be the worst possible outcome. It stays a **client** even so: it reaches a running
deployment over HTTP through `POST /v1/responses` and never reads a store directly.
`evals/run.rb` is a thin CLI over it.
