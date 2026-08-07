---
title: Refinement
parent: Operate & prove it
nav_order: 5
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
  does not count. It calls no model.
- **`safe_reply` cannot tell you which rule fired.** Guardrail decisions and
  edge-limit hits are emitted as events and never stored, so the canned reply in
  the transcript is their only durable footprint. The finding tells you the agent
  gave up; the guardrail configuration tells you why it might have.

Numbers and ids are normalized out of the grouping key, so `product 4711 not found`
and `product 4712 not found` are recognized as one defect.

## Who wrote a message

A `role` says where a message sits in the conversation, not who wrote it, and the two
come apart constantly: the engine delivers a subagent's result as a `user` turn, a
guardrail answers as `assistant` with no model involved, a consumer composes context
blocks into the input, and in an imported transcript a human operator types after a
handoff. Read without that distinction, the first run over real traffic reported
**219** "the customer repeated themselves" that were the engine reading its own
injected fragment back.

So a stored message may carry an `origin`:

| origin | who |
|---|---|
| *(absent)* | the natural producer for the role — a customer for `user`, the model for `assistant` |
| `customer` | a person, said explicitly |
| `agent` | the model, said explicitly |
| `engine` | Insika itself, or a consumer composing on its behalf |
| `operator` | a **human** on the assistant side (a handoff) — set by whatever imports the transcript |

The engine stamps what it truthfully knows: a delegation result it wrote, a guardrail
reply it produced. A consumer declares its own composed input by sending `"origin"` on
`POST /v1/responses`. Nothing else changes — a message with no origin reads exactly as
it did before, so no transcript needs migrating.

`repetition` counts only what a customer said and `safe_reply` reads only what the
engine said, both from this field. A message that declares nothing falls back to the
old guess (an injected fragment opens with its own tag, `<cacau_cep_obrigatorio> …`,
which no customer types) — that heuristic now runs only on messages that made no
claim about themselves.

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
| `mode` | `"report"` | `report` reads and writes nothing. `propose` allows a gated, human-approved edit (below). A mode the engine does not know is refused, never silently downgraded |
| `files` | none | the ONLY files a proposal may edit. Empty means report-only |
| `max_edits` | 3 | edits a single proposal may carry |
| `max_bytes` | 1200 | size of one edit's replacement text |
| `max_total_growth` | 0.15 | how much a proposal may grow a file, as a fraction of its current size |

## Events

A run emits two events, both counts and no content, so any subscriber (including
the OpenTelemetry bridge — see [Observability](OBSERVABILITY.md)) can watch it:

| Event | Data |
|---|---|
| `:refinement_started` | agent, run id, window |
| `:refinement_report` | agent, run id, status, findings, sessions, turns |
| `:refinement_proposed` | agent, run id, proposer, edits, dropped |
| `:refinement_gated` | agent, run id, passed, reason, cases, passed_cases, regressions |
| `:refinement_applied` | agent, run id, by, files, edits |
| `:refinement_rejected` | agent, run id, by |

File **names** appear on the applied event, because an operator needs to know what
changed. File **contents** never do.

## Changing the agent: the gate

A report tells you what broke. Changing the prompt because of it is a separate,
opt-in step, and the whole design is in one sentence: **a proposed edit is scored by
running it, and a human approves it before it reaches anyone.**

```
proposal ──▶ clone the agent ──▶ apply the edits to the CLONE ──▶ replay the golden
             set ──▶ compare to the accepted baseline ──▶ a human approves ──▶ write
```

Nothing here asks a model whether an edit looks good. That measures nothing. What
the gate measures is whether the agent still passes the cases it was passing, on
real turns, with its real tools and guardrails.

### What a proposal looks like

Data, not a rewritten file:

```jsonc
{
  "rationale": "Two findings share a cause: TOOLS.md never says the CEP is required.",
  "edits": [{
    "file":   "TOOLS.md",                              // must be in `files`
    "op":     "replace",                               // replace | append
    "anchor": "## shipping_quote",                     // a label for the reviewer
    "before": "Use shipping_quote to quote freight.",  // must still match, exactly and once
    "after":  "Use shipping_quote to quote freight. Always ask for the CEP first.",
    "addresses": ["tool_error:shipping_quote"]
  }]
}
```

Anchored and small is not a style preference. It makes the diff a five-second
decision instead of a code review, it makes the gate's result attributable to an
edit you can point at, and it makes staleness detectable: if `before` no longer
matches the file, the edit is dropped rather than applied by fuzzy match — which is
how a loop like this would otherwise silently overwrite something you wrote.

An edit that breaks a bound is dropped **with a reason** and the rest of the
proposal still goes to the gate. A proposal whose every edit dropped is refused
before anything runs.

### What the gate needs

Two things, and it refuses without either:

- **Golden cases for the agent.** No cases, no gate, no writes. Declaring them is
  the price of admission to automated editing — and the cheapest thing you can do
  to make this safe. See [Evals](EVALS.md).
- **A recorded baseline** — the accepted state of those cases:

  ```bash
  insika evals:import            # the corpus into the store
  insika evals:baseline import   # the accepted state, per agent
  insika evals:baseline show
  ```

  Without one, "did anything regress?" has no answer, and a gate that answered
  "nothing regressed" would be reporting that it did not look. So it refuses.

  It also refuses a baseline in which **nothing passes**. A regression is measured
  against a case that *was* passing, so an all-red baseline cannot produce one and
  every candidate — including a harmful one — sails through. If that is where you
  are, the agent needs fixing before it needs refining: get to a green run, record
  it, then gate.

The clone is a throwaway agent (`<agent>-cand-<run>`) with the same profile, tools
and guardrails, and it is deleted afterwards — including when the replay fails.
**Any** regression disqualifies the candidate. A case that was already failing does
not: refinement exists to fix those.

### Approving

A candidate that passes the gate parks the run at `awaiting_approval` and shows up
on the Refinement page with the diff, what it claims to address, and its score. You
approve or reject; nothing applies itself.

Approving writes each edit through the agent's file store, which versions the
previous content — so **rollback is the Restore button that was already there**, in
the file's History. There is no separate undo to learn.

Between the gate and your approval, someone may have edited the same file by hand.
The apply re-checks every `before` against the file as it is now and refuses the
whole proposal if anything drifted. A partial application would leave a prompt in a
state nobody reviewed and the gate never scored.

### What the gate can and cannot catch

Worth being precise about, because the gate is easy to trust more than it deserves.
Everything below was measured by running it against a real production-shaped agent,
not reasoned about.

**The gate is only as strong as your golden set.** This is the whole caveat and the
rest is detail. A regression is "a case that was passing now fails" — so an edit
that breaks something no case covers passes cleanly. Two shallow cases wave almost
anything through. If you want the loop to protect a behaviour, there has to be a
case for that behaviour; that is the price [D4](#what-the-gate-needs) is charging,
and it is charged in curation work, not in configuration.

Three things it will **not** catch, and two of them are the engine working correctly:

- **An edit cannot remove a tool, so the gate will never see one disappear.** Tool
  availability comes from the agent's `tools_allow`, not from prose. An instruction
  like "never call `search_products`" is advice the model routinely overrides; the
  tool is still attached and still gets called. If you want a tool gone, remove it
  from the agent — which refinement cannot do, by design.
- **PII in a reply is redacted before the gate could grade it.** The output
  guardrail runs on the turn, so a `must_not: [cpf]` case cannot fail because of an
  edit that tells the agent to leak one. The protection is real; it just means this
  is not the layer that measures it.
- **A small edit in a large prompt may change nothing at all.** A paragraph appended
  to the end of an 11 KB instruction set routinely loses to the rest of it. A gate
  pass on such an edit is honest — nothing changed — but it is not evidence that the
  edit *worked*, and approving it adds prompt with no effect.

What it does catch reliably is the class that matters most in practice: an edit that
changes **what the agent says** in a way one of your cases checks. Formatting,
tone, how much it asks before acting, whether it follows a policy. That is where
prompt edits have real leverage, and it is also where they do damage.

## What this is not

It does not propose the edit for you — a model writing the candidate is the next
phase, and it has to earn its place against a documented bar before it ships. It
has no scheduler: a run happens because a person or a cron asked for one. It cannot
touch your guardrails, tools, policies, model pins or limits, and not because a
prompt tells it not to — there is no code path (see [Security](SECURITY.md)).

And if the findings turn out to be noise in your deployment, the correct answer is
to stop at the report. That is a valid steady state, not a half-finished setup.
