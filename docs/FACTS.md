---
title: Facts
parent: Operate & prove it
nav_order: 6
permalink: /facts/
---

# Facts — distilled customer memory, human-gated

Finished conversations teach a shop things — the customer's size, their budget,
how they like to pay — and today that knowledge dies with the session. The
engine can read it back out of the transcripts: **distillation** turns an idle,
finished customer conversation into a list of proposed facts, a human approves
or rejects them in the Studio, and an approved fact lands in the customer's
memory cell — the same cell the `<memory>` block injects on every later turn.

The loop has one hard rule: **nothing is ever applied automatically.** Zero
facts reach the store without a click. Distillation proposes; the operator
decides; the engine never applies its own proposal.

## The loop

1. A customer conversation (a session tagged with a `customer`, per
   [Context](CONTEXT.md#memory)) goes idle — nobody has written for the
   configured hours.
2. The engine's distillation duty picks the session, sends its transcript to
   the platform `utility_model` (off the turn path, on its own worker fiber),
   and the model answers with a JSON list of durable facts: `name`, `value`,
   an optional `confidence`, and the transcript message indexes that support
   the fact (the **evidence**).
3. The engine filters the answer against a safe subset (no invented scopes, no
   oversized values, no out-of-range evidence), dedups it against the ledger,
   and writes the survivors as **proposals**.
4. The **Facts** page in the Studio shows the pending proposals with their
   evidence excerpt. The operator **approves** (the fact is written to the
   customer's memory, stamped with its origin), **rejects** (optionally with a
   reason) or **dismisses** (it will never be proposed again).
5. Approved facts join the customer's memory cell and are injected by the
   Memory provider on the next turn of any session of that customer.

## Enabling it — the `distill:` block

Distillation is pack data on the agent, exactly like `refinement:` or
`followup:` — absent = the feature is off for that agent, byte-identical engine:

```ruby
agent = Insika.agent("store-support") do
  instructions "…"
  distill enabled: true,
          idle_hours: 6,        # how idle a session must be before it distills
          min_messages: 3,      # a shorter session distills noise, not facts
          max_proposals: 10     # cap per session pass
  # prompt: "<what counts as a fact for THIS store>" — the pack-authored half;
  #   absent = the engine's generic prompt. `model:` (absent = the platform
  #   utility_model) can name the distiller explicitly.
end
```

The same keys work in a pack's `agent.config.json`. `idle_hours` /
`min_messages` / `max_proposals` are per-agent data; `prompt` is the store's
half — what counts as a fact for a fashion store ("size, preference, budget")
is not what counts for a logistics one ("address, delivery window, carrier").
The engine never writes store vocabulary.

## The human gate, precisely

The **Facts** page (operate group, next to Follow-ups) shows:

- **Pending** — oldest first, because evidence ages. Each card is the fact,
  its confidence, its scope (`tenant:customer`), and the evidence excerpt read
  from the transcript at request time (evidence is a link, never a copy). Three
  buttons: **Approve & save to memory**, **Reject** (with an optional reason,
  shown on the card), **Dismiss** (ghost — labelled "will not be proposed
  again").
- **Stale** — the CAS-lost re-present (below): the proposed value struck
  through next to the operator's current value, resolved by dismissal.
- **Recent** — every resolved proposal, most recent first, with operator and
  note.

**The latch** — a dismissed *or* rejected `(name, value)` tuple is never
proposed again. The proposal rows ARE the ledger: a human saw that tuple and
said no, and re-proposing it would train the operator to stop reading. An
unanswered proposal is never piled on, either. A *different* value for the same
name is a different tuple — "wears M" dismissed does not block "wears L".

**The CAS guarantee** — approval never silently overwrites an operator edit.
At distill time the engine records the target fact's existence and revision; at
approve time it writes through the store's optimistic compare-and-swap. A fact
the operator moved in between flips the proposal to `stale` with both values
visible — the operator's edit always wins, never a silent overwrite.

## Provenance

An approved fact is written with `origin: "distilled:<session_ref>"` — the
RFC-0031 provenance discipline: `"engine"` (the `remember` tool), `"operator"`
(Studio edits), `"legacy"`, and `"distilled"` (+ the session that produced it).
The Closed loop reads the same cell every later turn injects, and the
distillation ledger suppresses re-proposing a fact that is already applied with
a `distilled:` origin.

## LGPD

Distilled facts are personal data, and the engine treats them like it:

- **Forget a customer** — `forget_customer` purges the customer's proposals
  (every status) along with their memory cell and sessions.
- **Delete a tenant** — `delete_tenant_data` purges the tenant's proposals.
- **Retention** — proposals age out under the same `retention_days` sweep as
  the rest of the footprint (pending included — a proposal is evidence of a
  transcript, and when the transcript dies the pending fact is stale). The
  session marker dies with its proposals: **an unreviewed proposal that ages
  out is expired, not lost-locked** — the session is re-distillable, and a
  duplicate survivor is filtered by the ledger, never applied.

## The honest limits

- **Best-effort extraction, re-scan recovery.** There is no distillation
  queue. A crash mid-pass leaves the session unmarked; the next pass re-scans
  it, and the ledger filters any duplicate proposal. Exactly-once is not
  claimed — facts are re-derivable, and a duplicate is filtered, never applied.
- **Precision is a forge audit.** The engine guarantees the *gates* (schema,
  dedup, CAS, human approval); it cannot guarantee the *model's judgment*.
  "Is this fact true and durable?" is audited on real traffic, per store — the
  pack prompt is where that judgment is tuned.
- **Scope comes from the session, never the model.** The proposal's landing
  cell is assembled by the engine from the session's tenant and customer; the
  schema rejects a model-authored scope outright (a cross-tenant escape), and
  an untagged session is never distilled.
- **Sessions only.** Distillation targets customer-tagged sessions; a
  session without a customer has no landing zone and is skipped.
- **One stamp, once.** A session receives `vars["agent"]` on the same write
  that stamps its `customer` — the first tagged turn. The stamp is
  idempotent: a session that already carries a `customer` (a pre-upgrade
  conversation, or one that since moved to this agent) never gains `agent`
  on its own, so it can never participate in distillation.
