---
title: Refinement
parent: Operate & prove it
nav_order: 4
permalink: /refinement/
---

# Refinement

An agent in production teaches you something every hour, and by default none of it
comes back. The engine already records the evidence — every tool call with its
arguments and result, every transcript, every failed turn — and nobody reads it.
So the same wrong answer is served to the next customer until a human happens to
look.

Refinement is the loop that closes that gap. It reads a window of an agent's own
traffic and reports **what broke, how often, and in which conversations**.

Today that report is the whole feature. It calls no model and it changes nothing
about your agent — no prompt is rewritten, no tool is touched. That is deliberate:
a report you can read in thirty seconds is worth more than an automatic edit you
cannot verify, and it is the honest way to find out whether the evidence in your
own deployment is good enough to act on.

## Running one

From the CLI, against the same database the engine uses:

```bash
INSIKA_DB=insika.db bin/insika refine --agent bia
```

```text
bia — completed (last 200 session(s))
  tool_error     ×24   shipping_quote failed: cep is required
                       sessions: 9f2c1a04…, 4b7e5590…, c1d0aa31…
  repetition     ×7    customer repeated themselves
                       quero saber o frete, quanto fica pro meu endereço
                       sessions: 9f2c1a04…, 77bb0e12…
  safe_reply     ×3    a canned safe reply was served instead of an answer
                       sessions: 2a55f0c9…
  tool_unused    ×1    search_voucher was never called in this window
```

Or from **Studio → Refinement**: pick the agent, press Run, and the same report
renders with each session id linking to its transcript. Every finding is a claim
you can go and check.

There is no scheduler in the engine, by design. A run is one command
(`run_refinement`), and the CLI and the button are the two ways to fire it. If you
want it on a timer, point your own cron at the authenticated route the button uses
— that keeps the engine free of a background ticker and of the single-node
assumption one would bring.

```
insika refine ─┐
Studio button ─┼─▶ run_refinement ─▶ read the window ─▶ ranked report (stored)
your cron  ────┘                     (tasks, transcripts, tool traces)
```

## The window

By default, a run is **incremental**: it reads everything since the previous run
for that agent, so running it twice in a row is quiet. The first run — or any run
with `--full` — reads the configured window instead, which defaults to the 200
most recent conversations.

| Flag | Meaning |
|---|---|
| `--last-sessions N` | the N most recent conversations, however many turns those took |
| `--since ISO8601` | only turns from that instant on |
| `--full` | ignore the previous run and use the configured window |
| `--exclude PREFIXES` | drop sessions whose id starts with any of these (e.g. `loadtest-,debug-`) |
| `--json` | the run record as JSON, for a pipeline |

The window is stored on the run, so a report read months later still says what it
looked at.

## Synthetic traffic

If load tests, evals or debug conversations land in the same store as real ones,
they will dominate the report — on the pilot they outnumbered real conversations
and buried every genuine finding, including 203 turns failing for a reason that
only occurs under the load-test profile.

`exclude_sessions` (or `--exclude`) drops sessions by id prefix. It defaults to
**nothing**: a report does not get to decide what counts as real traffic. What it
dropped is counted on the run and shown next to the findings, so a filtered window
never reads like a clean deployment.

## What it looks for

Each finding is aggregated: forty instances of one broken argument are **one**
finding with a count of forty, not forty rows. Findings are ranked by count times
severity, and each carries up to five session ids as provenance — ids only, so the
record itself holds no conversation content.

| Finding | What it means | Read from |
|---|---|---|
| `tool_error` | a tool returned an error, grouped by tool and by a normalized error signature | tool traces |
| `task_failed` | a turn died, grouped by its error | the task's executions |
| `repetition` | the customer said the same thing twice in a row — the outside view of an instruction the agent is not following | the transcript |
| `safe_reply` | a canned safe reply reached the customer instead of an answer | the transcript |
| `tool_unused` | a tool the agent is allowed to use never fired in the whole window | profile vs tool traces |

Two notes on honesty, because a report that overstates what it knows is worse than
no report:

- **`repetition` is a heuristic**, not a judgment: token overlap between
  consecutive customer messages, with short messages ignored so a repeated "hi"
  does not count, and messages the *engine* injected into the transcript (a context
  provider can add a `:history` fragment as a user message) skipped — they are the
  engine talking to itself, and counting them produced 219 false positives on the
  first real run. It calls no model.
- **`safe_reply` cannot tell you which rule fired.** Guardrail decisions and
  edge-limit hits are emitted as events and never stored, so the canned reply in
  the transcript is their only durable footprint. The finding tells you the agent
  gave up; the guardrail configuration tells you why it might have.

Numbers and ids are normalized out of the grouping key, so `product 4711 not found`
and `product 4712 not found` are recognized as one defect.

## Privacy

A report may quote customer words — that is the point of the `repetition` snippet —
so every snippet goes through the same redaction a customer-facing turn does
(`[REDACTED:cpf]` and friends, see [Security](SECURITY.md)). Tool arguments and
results are never copied into a report at all; only the error signature is. And the
run record stores session ids, never their contents.

That redaction covers what the engine's detectors cover — formatted CPF/CNPJ and
API secrets. It is not a general PII scrubber: a phone number written into a chat
can survive into a snippet. Treat the Refinement page as what it is — an operator
surface behind the Studio login, next to the transcripts themselves.

## Configuration

Refinement needs no opt-in to report: reading your own traffic writes nothing, so
an agent with no configuration at all can be run. The optional block on the agent
sets the defaults:

```ruby
Insika.agent "bia" do
  model "deepseek-chat"
  refine window: { last_sessions: 200 }, max_findings: 20
end
```

| Key | Default | Meaning |
|---|---|---|
| `window.last_sessions` | 200 | conversations read when the run is not incremental |
| `max_findings` | 20 | cap on the report |
| `exclude_sessions` | none | session-id prefixes to drop |
| `mode` | `"report"` | `report` is all that exists today; a typo here is refused, never silently downgraded |

## Events

A run emits two events, both counts and no content, so any subscriber (including
the OpenTelemetry bridge — see [Observability](OBSERVABILITY.md)) can watch it:

| Event | Data |
|---|---|
| `:refinement_started` | agent, run id, window |
| `:refinement_report` | agent, run id, status, findings, sessions, turns |

## What this is not

It does not edit your agent, propose a change, or run your evals. Those are the
later phases of the same loop, and each of them has to earn its place: an edit that
reaches a customer must be verified against a graded test set and approved by a
human, with one-click rollback, or it has no business existing. The report comes
first because it is the part that is useful without any of that machinery — and
because if the findings turn out to be noise in your deployment, the correct answer
is to stop here.
