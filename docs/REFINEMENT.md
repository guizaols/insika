---
title: Refinement
parent: Improve
nav_order: 2
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

The report is the default and it is the whole feature until you turn on more: it
calls no model and it changes nothing about your agent — no prompt is rewritten, no
tool is touched. That is deliberate. A report you can read in thirty seconds is
worth more than an automatic edit you cannot verify, and it is the honest way to
find out whether the evidence in your own deployment is good enough to act on.

Opt in (`mode: propose`) and the loop goes one step further: a model proposes a
small, anchored edit to the instruction files you listed, the edit is scored by
**running** the agent's test cases with it applied, and a human approves it before
it reaches anyone. Every part of that is below, including what it cannot catch.

## Running one

From the CLI, against the same database the engine uses:

```bash
INSIKA_DB=insika.db bin/insika refine --agent demo
```

```text
demo — completed (last 200 session(s))
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

A run is one command (`run_refinement`), and the CLI and the button are the
two ways to fire it. There is still no built-in timer *for the report itself*,
but there is one for the *agent*: fine-grained recurring turns live in
[Schedules](SCHEDULING.md), and a refinement run scheduled like any other turn
is just a message the agent's schedule sends it. If you prefer to stay outside
the engine, pointing your own cron at the authenticated route the button uses
works just the same — both paths are supported, the engine's trigger is the
built-in one.

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
old guess (an injected fragment opens with its own tag, `<store_cep_required> …`,
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
Insika.agent "demo" do
  model "deepseek-v4-flash"
  refine window: { last_sessions: 200 }, max_findings: 20
end
```

| Key | Default | Meaning |
|---|---|---|
| `window.last_sessions` | 200 | conversations read when the run is not incremental |
| `max_findings` | 20 | cap on the report |
| `exclude_sessions` | none | session-id prefixes to drop |
| `mode` | `"report"` | `report` reads and writes nothing. `propose` allows a gated, human-approved edit (below). `auto_apply` lets a gate-passing edit land unattended — off by default, and read [what it costs you](#applying-without-a-human) first. A mode the engine does not know is refused, never silently downgraded |
| `files` | none | the ONLY files a proposal may edit. Empty means report-only |
| `proposer` | the platform `utility_model` | which model writes the candidate (`"deepseek/deepseek-v4-flash"` or a bare model name). Neither set means no proposal — the engine never picks a model to spend your budget on |
| `proposers` | falls back to `proposer` | a **panel**: several models, each writing its own candidate. `["deepseek/deepseek-v4-flash", {model: "gpt-5-mini", provider: "openai"}]` — either syntax |
| `budget.tokens` | unlimited | what one run may spend across every proposal and every gate replay |
| `max_edits` | 3 | edits a single proposal may carry |
| `auto_apply_max_edits` | 1 | edits an **unattended** apply may carry. A bigger diff waits for a person |
| `max_bytes` | 1200 | size of one edit's replacement text |
| `max_total_growth` | 0.15 | how much a proposal may grow a file, as a fraction of its current size |

## Events

A run emits two events, both counts and no content, so any subscriber (including
the OpenTelemetry bridge — see [Observability](OBSERVABILITY.md)) can watch it:

| Event | Data |
|---|---|
| `:refinement_started` | agent, run id, window |
| `:refinement_report` | agent, run id, status, findings, sessions, turns |
| `:refinement_proposed` | agent, run id, candidates, proposers, edits |
| `:refinement_gated` | agent, run id, passed, reason, cases, passed_cases, regressions, candidates, tokens |
| `:refinement_applied` | agent, run id, by, files, edits |
| `:refinement_rejected` | agent, run id, by |
| `:refinement_auto_apply_skipped` | agent, run id, edits, max_edits |

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

### Who writes it

You can hand a candidate to the API yourself. Or press **Propose a fix** on a
finished report and the model named by `proposer` writes one, from the findings and
the current text of the allowlisted files.

That model is the weakest link in the loop, and it is built to be. It is shown the
evidence and the files it may edit; it produces data that is then bounded (allowlist,
size, growth, an anchor that must still match) and **scored by replaying your golden
set**. A hallucinated rationale, a misread finding, an invented anchor — the worst
outcome of each is a candidate that gets dropped or fails to move a score, and never
reaches a customer. Nothing it says is trusted; it is measured.

Three things follow from that, and they are worth knowing before you press the
button:

- **It only sees the files on your allowlist.** Not the rest of the prompt, not your
  guardrails, not your tools. A model that can read a file it cannot edit proposes
  edits to it, which drop, which spends your attention on rejects.
- **It only sees findings.** A run with none refuses to propose rather than inventing
  an improvement to a prompt that is working.
- **It costs money twice** — once to write the candidate, once for the gate's replay,
  which is a real conversation per case. So a proposal is a deliberate press, never a
  timer, and the engine refuses if no `proposer` is configured rather than picking a
  model for you.

The report and the proposal run in the same place they always did: `insika refine`
and Studio → Refinement. The proposal is Studio-only, because the gate's replay goes
through the deployment's own `/v1/responses` — the CLI runs without booting the app,
which is what makes it safe against a live volume, and it is not going to start a
server to grade an edit.

**What the proposals actually look like**, from running this against a real
production-shaped agent (a 22 KB persona, an 11 KB tool guide, seventeen findings
from its own traffic): most were edits a human would have made — reuse the search
result you already have instead of searching again, say one honest sentence when a
tool fails instead of retrying it. One was not, and it is the failure mode to know
about: **an infrastructure finding invites prose that cannot work.** Shown tool
errors that were really a blocked destination and a refused connection, the model
proposed instructing the agent to "always use https" — advice about something the
agent does not control and cannot obey. Naming that trap in the proposer's own
instructions removed it, and the model now says out loud which findings it is
declining to address. It will not catch every case: when you review a proposal, the
first question worth asking is whether the finding it addresses is behaviour at all.

### More than one proposer

`proposers` asks several models the same question and gates every answer:

```ruby
refine mode: "propose", files: %w[TOOLS.md],
       proposers: ["deepseek/deepseek-v4-flash", "gpt-5-mini"],
       budget: { tokens: 200_000 }
```

They are **independent, not consensus-seeking**. Each is shown the same findings and
the same files and writes its own candidate; the gate then scores each one and you
are shown the best survivor, with the others listed under it. Convergence only ever
breaks a tie: two models agreeing on wording is weak evidence, and a golden case
passing is strong evidence. Ranking is highest score, then the smaller diff, then how
many models converged.

Two models that write the *identical* edit are gated once, not twice — the agreement
is recorded and the replay is not paid for again. A model that answers prose, times
out or 500s takes itself out of the panel and the rest proceeds; all of them failing
is an error, not a silent empty result. The panel runs concurrently and is capped at
the subagent fan-out (8, `INSIKA_SUBAGENT_FANOUT_CAP`).

A panel of one is exactly what `proposer` already did, which is why nothing changes
for an agent that names a single model.

### What a run may spend

A panel of 3 over a 7-case golden set is 3 model calls plus **21 replayed
conversations**, each a real turn with real tools. That is the honest objection to
this whole feature, and `budget.tokens` is the answer to it: a ceiling checked before
each expensive step, never in the middle of one. A candidate the run could not afford
is recorded as "not gated — the budget was spent", never dropped in silence, and the
run's cost is on the record where you can see whether the loop earns its keep.

Two things to know about the number.

**It counts the prompt cache.** A turn on a 27 KB pack reports `total_tokens: 88` with
`cached_tokens: 26624` — the engine's `total_tokens` is input + output and deliberately
excludes the cached prefix. A budget built on that alone would let a run send hundreds
of times what its ceiling said, so the budget bills `total + cached` and records the
cached share separately. On a real panel run against the pilot: **382,325 tokens spent,
362,752 of them cached** — 95%. Cached tokens are cheaper than fresh ones; they are not
free, and a ceiling has to see them.

**And when a provider reports nothing**, that leg is tallied as *unmetered* rather than
as zero, because a budget that quietly reads unmetered spend as free stops being a
budget. If your provider is silent, the bounds that still hold are structural: the
fan-out cap on the panel, `max_edits`, and the gate's own refusals.

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

- **A judge, if your baseline was recorded with one.** A rubric'd case with no judge
  verdict counts as a pass, so replaying without a judge against a judged baseline
  does not measure less — it measures backwards, and every candidate reads as an
  improvement. Measured: gating the pilot with no judge configured reported **6/6, no
  regression** against a baseline the same corpus had just scored **2/6**. So the gate
  refuses that combination. Configure the panel in Studio → Settings → Evals (or
  `settings["evals"]["judges"]`), or re-record the baseline without a judge — then both
  sides are equally deterministic, which is weak but not inverted.

  With the judge on, the same two candidates were **rejected**: both dropped
  `status-pedido` from 1.0 to 0.7, one also dropped `saudacao`. That is the gate doing
  its job, on edits the broken version had waved through.

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

### Applying without a human

`mode: "auto_apply"` is the one setting that lets a prompt change while nobody is
watching. It is off by default and it is deliberately narrow — it needs **all** of:

- the mode, set explicitly on that agent;
- a gate **pass** with zero regressions (a refused candidate is never auto-applied);
- a diff no larger than `auto_apply_max_edits`, which defaults to **1**.

A candidate that passes but is too large is **not rejected** — it waits for a person.
"Too big to apply unattended" and "wrong" are different verdicts, and collapsing them
would throw away a proposal the gate already paid to score.

An unattended apply goes through the same code an approval does: the same staleness
re-check, the same versioned write, the same `:refinement_applied` event. So the undo
is the same one — Restore in the file's History — and the Refinement page shows what
changed, why, and the link to get there.

The honest framing: this trades your review for your golden set. It is worth turning
on when the cases genuinely cover the behaviour you care about, and it is a bad idea
before that — see [what the gate cannot catch](#what-the-gate-can-and-cannot-catch),
which is the list of things auto-apply will happily wave through.

### What the gate can and cannot catch

Worth being precise about, because the gate is easy to trust more than it deserves.
Everything below was measured by running it against a real production-shaped agent,
not reasoned about.

**The gate is only as strong as your golden set.** This is the whole caveat and the
rest is detail. A regression is "a case that was passing now fails" — so an edit
that breaks something no case covers passes cleanly. Two shallow cases wave almost
anything through. If you want the loop to protect a behaviour, there has to be a
case for that behaviour; that is the price [the gate](#what-the-gate-needs) is charging,
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

A run happens because a person or a cron asked for one — the refinement
pipeline has no timer of its own, and if you want one, a schedule
([Schedules](SCHEDULING.md)) makes a run a turn any agent can be scheduled to
send. A proposal is written when you ask for
one, and — unless you turned on [`auto_apply`](#applying-without-a-human), which is
off until you do and bounded when you do — applied when you approve it. And it cannot
touch your guardrails, tools, policies, model pins or limits, and not because a prompt
tells it not to — there is no code path (see [Security](SECURITY.md)).

And if the findings turn out to be noise in your deployment, the correct answer is
to stop at the report. That is a valid steady state, not a half-finished setup.
