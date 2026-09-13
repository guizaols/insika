# Commerce Confirmation Pilot Implementation Plan

> **CLOSED 2026-09-13 — not executed, and deliberately so.** Step 1 asked for the
> real pack and tool names before anything live. They say the pilot has no target:
> no store agent in the fleet can write an order. Closing is a `<finalizar/>`
> marker or `send_finalize_button`, both of which send a **button** the customer
> taps, with payment in the backend checkout. That tap is already a stronger
> agreement than a chat "sim", and `customer_confirm` has nothing to hold.
>
> Doing it by prompt would mean giving the agent an order-writing tool — creating
> the hazard first, then installing the guard against it, to land roughly where
> the button already is but with the model's reading of "sim" in the loop. The
> store owner's call, 2026-09-13: **don't**.
>
> Step 2 ran anyway and earned its keep: it found a real prompt defect and fixed it
> (`evals/bench/cuts/2026-09-12-pilot-gate/`). Steps 3 and 4 were never started —
> no pack was edited, nothing was activated.
>
> Findings: `2026-09-12-commerce-confirmation-pilot-record.md`.
> Reopen only for a deployment with a native checkout that writes an order from a
> chat turn. The open question that remains is a funnel one, not a gate one: is the
> button costing conversions? Measurable today, no engine change.


> **Status: not applicable to current stores. Do not execute this pilot.** The original proposal below is retained as history, not an active implementation plan.

## Deployment correction

The user confirmed that none of the 22 current stores exposes a tool that creates
orders. `send_finalize_button` sends a checkout button; the customer proceeds by
tapping it, with the purchase completed in the checkout. The agent does not close
an order through text. There is therefore no order write for `customer_confirm`
to hold in these deployments.

- Keep the existing button/checkout flow. Do not add an order-writing tool or a
  conversational confirmation step to make this pilot applicable.
- Retain the synthetic bench as evidence about the generic runtime capability.
  Reconsider a pilot only if a real deployment independently needs agent-executed
  order creation.
- The 67 unwanted orders in the direct benchmark arm are not an estimate of risk
  in today's button-based stores. In 60 of those cases, the benchmark's later
  refusal/question/amendment arrived after an earlier explicit checkout request;
  those cases measure a reconsideration window, not 60 initially unauthorized
  purchases.
- If checkout conversion becomes the concern, first establish what existing
  records can correlate button delivery, customer interaction and completed orders.
  No funnel measurement or checkout change has been authorized by this correction.
- The reported Ocean Drop mismatch between `AGENTS.md` and `TOOLS.md` is a separate
  documentation/tool-configuration question. Its production allowlist impact remains
  unverified and is not a reason to activate this pilot.

## Original proposal — inactive

**Goal:** Pilot customer-confirmed checkout in one store without asking customers to confirm ordinary cart additions.

**Architecture:** Keep the existing generic `customer_confirm` mechanism. Make one focused edit to the selected deployment's pack, validate it in the existing bench, then review a small live cohort using existing traces and backend order records.

**Tech Stack:** Existing Insika profiles/packs, MCP tools, Ruby evals and Docker Compose. No new runtime feature, dependency or dashboard.

**Spec:** The preceding conversation: clear additions execute immediately; checkout requires confirmation; repeat scenario 16 before a limited pilot; review every checkout and measure abandonment after the additional question.

## Evidence and constraints

- Read the repository's `README.md`, `docs/ARCHITECTURE.md`, `CONTRIBUTING.md` and `docs/TOOLS.md` before execution.
- `evals/bench/cuts/2026-09-12-confirmation/recheck-16/` contains 20 correct purchases, 20 holds and 20 confirmations, without duplicate purchases or detected premature purchase claims.
- The complete scenario passes only 18/20 times. Repetitions 2 and 7 delay `add_to_cart` until turn two and ask an unnecessary question on turn one.
- The bench prompt already says to add before asking (rule 5). Edit that rule if needed; do not append another contradictory or redundant instruction.
- The reference store is synthetic. The live merchant, agent, pack location and deployment owner have not been selected. Resolve those before live activation; never infer them from the bench persona.
- This document is a plan, not a production activation. Preserve historical cuts and existing production configuration.

## 1. Prepare one deployment change

**Files:** The selected store's existing pack, located during this step; `evals/bench/prompt/AGENTS.md` only to mirror the candidate wording for validation.

- [ ] Select one store and its existing agent. Record the real pack path, agent ID, tool names, deployment owner and current configuration revision in the pilot record.
- [ ] Trace the actual cart and order tools. Configure `customer_confirm` for the tool that creates the order; exclude ordinary add/remove operations. Retain provenance checks, backend validation and any existing operator controls.
- [ ] Save the original pack revision and a concrete restoration procedure. Do not put credentials or customer data in the repository.
- [ ] Replace the pack's existing add/checkout instruction with this intent, adapted only to its real tool names:

```text
Quando o pedido para adicionar estiver claro e o produto estiver identificado,
adicione ao carrinho sem pedir confirmação extra. Se faltar uma informação
necessária, pergunte somente por ela. Só diga que adicionou após a ferramenta
confirmar sucesso. Para finalizar a compra, apresente o pedido e peça a confirmação
exigida pelo sistema. Não peça essa confirmação para adicionar ou remover itens.
```

- [ ] Check neighboring rules and skills for conflicting requirements. Keep one authoritative instruction; do not remove clarification needed to identify an item or variant.

**Done:** A reviewable pack diff exists, and only the irreversible checkout operation uses customer confirmation.

## 2. Validate before activation

**Files:** `evals/bench/prompt/AGENTS.md`, existing `evals/bench/confirmation/tasks/16-sim-duas-vezes.yml`; new evidence under a separate `evals/bench/cuts/` directory.

- [ ] Mirror the candidate rule in the synthetic bench prompt. Keep the model, provider routing, reasoning and runtime unchanged from the recheck; verify the provider remains available before running.
- [ ] Record the effective model explicitly, the source revision, image ID and actual prompt hash. The earlier recheck manifest has `model: null` and `dirty: true`; do not carry those provenance gaps into the new result.
- [ ] Rebuild the image and run one smoke of scenario 16, confirmation enabled. Confirm that the saved calls include the hold and subsequent decision.
- [ ] Run 20 new repetitions of scenario 16 using the existing runner's `ARMS=true`, `REPS=20` and `TASKS_GLOB='16-*.yml'` options, with a fresh `OUT` and `BENCH_REPORT`. Run no other bench concurrently: the runner resets shared bench containers and volumes.
- [ ] Inspect all checks, not just the report's Bought column. Require `add_to_cart` on turn one, no question seeking permission to add, a checkout hold before execution, one successful order after confirmation, and no second checkout attempt on repeated consent.
- [ ] Inspect reply wording as well as the regex grader. A question about an optional additional product is different from asking permission to carry out the current clear request.
- [ ] Run one regression smoke each of tasks 07, 09, 10, 13, 14 and 15 under the candidate prompt. Require correct cart/order outcomes, no invented successful action and correct cancellation/expiration behavior.
- [ ] Preserve failures and provider errors. Do not replace a failed cell with a retry; a changed candidate gets a separate sample and manifest.

**Gate:** 20/20 complete scenario-16 passes, no unnecessary pre-add confirmation in those transcripts, and six clean regression smokes. This is a pilot entry criterion, not a reliability claim. Failure returns to the pack change; runtime changes require a reproduced runtime defect.

## 3. Activate a bounded live pilot

**Scope:** One store, at most 50 conversations reaching a checkout proposal, over at most seven days. Review the first ten before admitting the remaining forty.

- [ ] Prepare the candidate configuration, validation results and pause procedure for the deployment owner. Obtain live activation authorization after the change is reviewable.
- [ ] Use the deployment's existing cohort/routing controls. If it cannot limit traffic, use supervised enrollment; do not build a feature-flag service for this pilot.
- [ ] Keep each enrolled conversation on one configuration revision throughout its pending confirmation. Start with new conversations; do not switch agents mid-purchase.
- [ ] Before enrolling real customers, verify in the selected deployment's safe test environment that a hold writes no order, agreement writes exactly one order, and refusal or changed intent cannot execute the old proposal.
- [ ] Review every checkout against the backend order record and its conversation trace. Use the same access-controlled operational records already used by the store; do not publish customer transcripts as bench fixtures.

## 4. Measure and decide

Use a small review table; one row per enrolled conversation. Record configuration revision, proposal time, decision, write time, order correctness, reply correctness, unnecessary pre-add questions and extra customer messages. Reuse existing traces; no new funnel is required.

| Measure | Definition |
| --- | --- |
| Purchase without confirmation | A backend order without an applicable customer agreement after the held proposal |
| False success statement | The reply reports an addition or purchase that had not succeeded at that point |
| Wrong or duplicate order | Backend items/quantities differ from the confirmed proposal, or the same purchase executes twice |
| Unnecessary confirmation | A clear, actionable cart request is delayed for permission to add/remove |
| No reply after confirmation request | No customer reply within 24 hours of the checkout question; separate from an explicit refusal or changed request |
| Purchase completion | Correct completed purchases divided by conversations reaching a checkout proposal; also show completion among affirmative replies |

- [ ] Review after the first ten eligible conversations and at the sample/time limit. Allow the last 24-hour observation window to close before reporting non-response; otherwise mark that observation pending.
- [ ] Report counts and denominators. Non-response after the question is not proof the question caused abandonment; a historical comparison is descriptive, not a randomized control.
- [ ] Immediately pause automated checkout for the pilot on a purchase without confirmation, an incorrect/duplicate purchase or a false success statement. Route affected conversations to the store's existing human workflow. Do not disable `customer_confirm` as the rollback: that would remove the protection being tested.
- [ ] Preserve and resolve pending proposals explicitly during a pause; do not automatically replay them after restoring configuration. Record the incident and reproduction before resuming.
- [ ] Expand only after reviewing all sampled checkouts, with no unresolved execution/claim defect and the store owner accepting the measured extra interaction and non-response rate. If friction is unacceptable, revise the pack or presentation before adding more traffic.

**Deliverable:** One pilot report with the pack diff, bench evidence, live counts, observed failures and an explicit expand/pause decision. The harness remains generic; commerce behavior stays in deployment configuration.
