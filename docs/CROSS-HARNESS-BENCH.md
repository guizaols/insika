---
title: Cross-harness bench
parent: Operate
nav_order: 7
permalink: /cross-harness-bench/
---

# Cross-harness bench — the same store, six harnesses

Six agent harnesses answer the same twelve customer conversations against the same
MCP store, on the same model at the same reasoning setting, graded on the store's own
state. It answers a question the engine benchmark deliberately does not touch: not
"what does the engine cost per turn" but "does a shop staffed by this agent behave".

This is a **different suite with a different contract** from
[Benchmark](BENCHMARK.md), which measures engine overhead with no provider, no key and
no competitor. This one needs a provider key by design — a commerce conversation
cannot be stubbed — and it names other harnesses. Read the publication rule at the
bottom before quoting anything from it.

## Running it

```bash
cd evals/bench
cp .env.example .env      # OPENROUTER_API_KEY, BENCH_MODEL
docker compose build      # six images, every version pinned
bash cut3.sh              # ~4-5h, ~$6, resumable
```

`RUNBOOK.md` in that directory is the operator's copy: the traps already paid for, the
resumability contract, and what to do after the run. Every entrant is a pinned Docker
image driven through the same one-JSON-in, one-JSON-out adapter; the store is reset
between every cell; three rounds is the floor, because a single run is not a
measurement.

## Two scorecards, and why

**A is parity** — same tools, same model, same prompt, none of anyone's own product
layer, ours included. **B is out of the box** — each harness as it ships. The distance
between a harness's two rows is what its product adds over the bare harness.

That distance is the number this bench was built to produce. In cut 3 it was zero for
us: scorecard B did not show our commerce layer paying for itself, and it was published
as a null result. In cut 4, with the one irreversible write held for the customer's
word, it is one cell — and that cell is described below, because one cell is a
mechanism to read, not a number to quote.

## What cut 3 found, for us

Twelve tasks, three rounds, `deepseek/deepseek-v4-flash` at reasoning `medium`, run
2026-09-09.

| | Scorecard A | Scorecard B |
| --- | --- | --- |
| Passed | 34/36 (94%) | 34/36 (94%) |
| Tokens per success | 2170 | 2263 |
| Wall clock p50 | 10.0s | 11.8s |

Two findings hold regardless of where the other rows land:

**Cost is where the spread is.** Accuracy across the field sits inside eleven points;
tokens per success spans an order of magnitude. Ours is the cheapest row on both
cards, at comparable accuracy. When five harnesses answer equally well, what separates
them is what they spend answering.

**Take the rules out of the prompt and the field separates.** The shared `AGENTS.md`
carries the rules the three hardest tasks test, which means a guarded cut partly
measures the prompt. Re-run with those rules removed, our rows hold at 9/9 on both
scorecards while the field spreads from 44% to 100%. That is the engine holding a rule
the prompt no longer states — the closest thing to a claim in this bench, and it is
about the engine, not about scorecard B.

## What cut 4 found, for us

Same model, same setting, run 2026-09-11, with our scorecard-B entry declaring
`customer_confirm "create_order"` — the close is held until the customer's next
message confirms it — and task 07 given the third turn that makes that answerable.

| | Scorecard A | Scorecard B |
| --- | --- | --- |
| Passed | 35/36 (97%) | 36/36 (100%) |
| Tokens per success | 2349 | 2890 |
| Wall clock p50 | 11.6s | 8.7s |

The one A cell we lose is task 09: *"adiciona logo por favor"* over two units already
in the cart, and the parity entry closed the order. The B entry, same engine, wrote no
order in any round of that task and closed task 07 on the confirming turn every time.
That pair of rows is the distance between A and B made of exactly one thing, and it is
the thing [Agents](AGENTS.md#do-not-offer-the-irreversible-action) describes: an
action the reply may offer freely because the engine will not run it in the same turn.
Three rounds is the floor, not a proof; the mechanism is in `docs/TOOLS.md`, the cells
in `evals/bench/cuts/2026-09-11/`.

Claude Code did not run this cut — the provider's Anthropic-shaped endpoint returned
nothing visible to it, with the same image that scored 94% two days earlier. Its cells
are kept outside the scorecard; a row that cannot run is not a row that ran badly.

## Reasoning is a deployment variable, not an axis

Every entrant is pinned to `medium` because that is what production runs. Crossing
reasoning against the table is eight combinations and roughly 1500 cells, so it gets
its own arm instead: ours against itself, both scorecards, at `medium` and at `off`.

Better on one card, worse on the other, with the same three tasks failing at both
settings. A focused probe — the three tasks we lose, ten rounds each — came back 24/30
at medium and 27/30 at off, the three tasks contradicting each other. **Reasoning does
not decide these cases.** Choose it on cost and latency.

## Reading a cut

`scorecard.rb` says who scored what. `viewer.rb` says what was actually said, which is
the question every finding here has turned on:

```bash
evals/bench/viewer.rb --runs cuts/2026-09-09
open evals/bench/bench.html
```

One self-contained HTML file: a harness-by-task matrix, and behind each square the
verdict, the checks that failed with their detail, and the whole conversation — the
customer's line, the reply verbatim, the tool calls, the timing. Every cell is also a
JSON file under `evals/bench/cuts/<date>/`, so any table here can be recomputed or
contested.

## Publication rule

**Everything here is published with its evidence. The comparison table is not a
ranking we will quote until someone outside this repo has reviewed the configs.**

Every entrant's configuration in this repo was written by us, and cut 3 found two
failures in our own wiring before anyone else did:

- OpenClaw's config carried a thinking level under `reasoningDefault`, which is a
  visibility setting taking only `on|off|stream`. OpenClaw rejected the whole config
  and ran no turn; the adapter read an empty answer off the error object and scored it
  as a harness that answered nothing. Seventy-two cells published a broken row as 33%.
  Fixed, the same harness scores 97% on both cards.
- Fifteen Hermes cells resumed from an earlier session had run against a store image
  that was never rebuilt after its code changed.

Both were caught by someone reading transcripts, not by the bench. So the tables ship
with every cell behind them — anyone can reproduce a row or show it is wrong — but
until each entrant's configuration has been reviewed by someone who does not maintain
this repo, **we do not cite another harness's row as a ranking** in comparative or
marketing material. Our own rows carry no such problem: we can read our own config.

Publishing the numbers and declining to market them is the point, not a hedge. A
ranking whose losing rows we wired ourselves is worth less than a bench anyone can
clone, rewire and re-run — and the two failures above are the argument for that, not
against it. Fix an entrant's config, re-run one harness, send back the cut.

## See also

- [Benchmark](BENCHMARK.md) — engine overhead: neutral, keyless, reproducible.
- [Evals](EVALS.md) — the grading corpus and the runner this bench drives.
- [Agents](AGENTS.md#do-not-offer-the-irreversible-action) — what the bench taught us
  about writing a store agent's prompt.
