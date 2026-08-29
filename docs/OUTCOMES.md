---
title: Outcomes and follow-ups
parent: Improve
nav_order: 3
permalink: /outcomes/
---

# Outcomes and follow-ups

## Outcomes — business results over real traffic

The engine measures what it is told to measure. The operator or the integration
records a conversation's business outcome after the fact — `conversion`,
`escalation`, `deflected`, anything, optionally with a monetary `value`:

```bash
curl -X POST /v1/outcomes -H "Authorization: Bearer $TOKEN" \
  -d '{ "agent": "store-support", "session_id": "chat-7",
        "outcome": "conversion", "value": 129.9 }'
```

The endpoint is **additive and outside the response contract** — the turn never
knows or cares; the engine transports the outcome and never interprets it (what
"conversion" means is yours). Records are tenant-stamped (a tenant principal
writes and reads only its own), and `GET /v1/outcomes?agent=` serves the last
outcome per agent plus the per-day series — the last-outcome pill on the Studio
agent grid, and the per-day series on the agent detail.

### The outcome funnel

A store's funnel is pack data on the agent — the engine folds outcomes into
the **declared** stages, and never hard-codes one itself (the stage vocabulary
is the forge's):

```ruby
agent = Insika.agent("store-support") do
  instructions "…"
  funnel stages: %w[greeted qualified cart paid],
         advance_on: { "abandoned_cart" => "cart", "pix_paid" => "paid" },
         primary: "paid", attribution_window: "72h"
end
```

The fold contract:

- **Tick-driven, cumulative event counts on the declared order.** An outcome of
  kind K means the session *reached* `advance_on[K]`; the fold increments
  `stages[0..index]` for the reached stage. A per-stage-complete integration
  and a terminal-event integration therefore produce identical counts — a
  session that paid also emitted the earlier events. A duplicate event
  double-counts (the integration's defect, not the engine's); **do not declare
  a stage off the linear path** (a "handoff" stage would be inflated by every
  later event). Counts are **event counts, not distinct sessions** — the
  baseline is events-based.
- **Idempotent**: a per-pair `{at, ids}` cursor inside one transaction; a crash
  mid-fold never double counts, and a second pass folds only what is new.
- **The attribution window is carried data, never computed** — `72h` is
  validated, rendered, and copied into the baseline snapshot; causal
  attribution stays human.
- **The baseline freeze** (Studio > Funnel, or `:freeze_funnel_baseline` on the
  bus) sums the folded cells over a span of **≥ 28 days** (shorter spans are
  refused) into one current snapshot per `(tenant, agent)` — the number
  the follow-up A/B and the harvest promotion gate compare against.
- **Malformed declarations never crash the tick**: the fold skips them, the
  doctor names the defect, the Studio shows nothing until it is fixed.
- Vocabulary note: in the gem this is the **outcome funnel** — the stage names
  are the forge's, and a bare install (no `funnel:` on any agent) shows no
  funnel and no stage names at all.

## Follow-ups — the seller who comes back

The agent can book a follow-up with a customer at a future time — "te chamo
amanhã se o PIX não cair" said in-conversation and meant. The engine fires the
synthetic turn on its own tick, with consent and without spam. Everything is
pack data on the profile:

```ruby
agent = Insika.agent("store-support") do
  instructions "…"
  followup arm: "schedule",
           policy: { quiet_hours: { timezone: "America/Sao_Paulo",
                                    start: "21:30", end: "09:00" },
                     max_frequency: "2/24h",       # N outbound per window, per customer
                     cancel_keywords: ["não quero mais contato"],
                     silence_after_sends: 3 }      # N fires without a reply -> :unavailable
end
```

The pieces:

- **`schedule(at:, reason:)`** — a built-in tool the agent calls when the
  customer agrees to be contacted again (a product, a cart, a pending payment).
  The call itself IS the consent record — recorded without ever lifting
  `:unavailable` or resetting the silence counter (ONLY a customer message
  reopens, so a re-booking inside a follow-up turn cannot clear the silence
  protection). `cancel_followup(id:)` is the sibling. A customer who opted out
  can never be rescheduled.
- **Contact state per customer** — `granted | revoked | unavailable` in a
  durable cell per `(tenant, customer)`. Only `granted` may be messaged;
  `revoked` is immediate and permanent until the customer speaks again;
  `unavailable` means silence ≠ refusal — the engine stops firing after
  `silence_after_sends` unanswered sends, and ANY customer message reopens.
  The policy's `cancel_keywords` are matched on every inbound message: a
  match revokes the contact and cancels its pending follow-ups in one
  transaction.
- **Firing is the tick's third duty** — the engine claims the due records
  (one per claim window, at-most-once across workers), applies the policy in
  force AT FIRE TIME (contact state, quiet hours, dedup per
  `(customer, reason)`, frequency ceiling) and either enqueues the synthetic
  turn or marks the record `blocked` with the failing rule — auditable, never
  silent. Blocking happens at fire time, never at schedule time: the schedule
  is a promise made in-conversation, and only the policy in force then may
  revoke it.
- **The synthetic turn** — a first-class inbound turn stamped
  `origin: "scheduled"` (a refinement read can never mistake the engine's
  kick for the customer repeating themselves), delivered through the full
  pipeline on the channel the conversation came in on. It skips the edge's
  ENTRY rate/token checks like a resume does — a follow-up she agreed to must
  not receive the rate-limit reply; its usage still lands on the ledger.
- **The Follow-ups page** (Studio) — per agent: the pending/fired/cancelled/
  blocked records (blocked rows carry the reason), the read-only policy
  summary and the A/B card: per arm, `sent` vs `conversions` (against the
  frozen baseline) vs `opt-outs`. The only mutations — cancel a pending
  record, force-revoke a contact — go through bus commands.
- **LGPD** — the records and cells die with the customer (`forget_customer`),
  the tenant (`delete_tenant_data`) and age out under the same
  `retention_days` sweep as the rest of the footprint.

Absent `followup:` = the feature is off for that agent — no tools wired, no
records, byte-identical turns. The A/B against an existing cron is an
operator experiment: the engine only keeps the records and the read card (the
cron arm writes through the same store class with its own `arm` label).

## See also

- [Evals](EVALS.md) — the cases that grade an agent before traffic does.
- [Refinement](REFINEMENT.md) — reading an agent's own traffic back as a report.
