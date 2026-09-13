# Pilot record — step 1, the store selection

**Store:** Natura. **Outcome: the pilot does not apply, and the reason is not specific to Natura.**

## What was found

| | |
| --- | --- |
| Pack | `openclaw-state-staging/workspace/agent-store-natura4/` — **untracked** in this repo; a staging snapshot, not the deployed revision |
| Engine | **OpenClaw**, integrated through `achei-b2b/app/clients/integrations/openclaw/` — not Insika |
| Agent tools | `search_products`, `recommend_products`, `add_to_cart`, `update_cart_quantity`, `remove_from_cart`, `reopen_cart`, `reset_cart`, `search_faq`, `search_orders`, `call_support` |
| Order-creating tool | **none** |
| Deployment owner | not established — no live activation was attempted |

## Why `customer_confirm` has nothing to attach to

The agent cannot write an order. Checkout is a marker: the agent emits
`<finalizar/>`, the system appends a **"Finalizar pedido"** button, the customer
taps it, and coupon, address and payment run in the backend flow. `TOOLS.md:202`
records that `send_finalize_button` was deliberately **removed** from this pack's
schema.

So the irreversible write the pilot wants to hold is already held — by a button
tap and a completed checkout, which is a stronger signal of agreement than a
"sim" typed in a chat. Adding `customer_confirm` would put a chat question in
front of a button that already asks. That is the friction step 4 exists to
measure, bought for nothing.

The only tool it could be attached to is `add_to_cart`, which step 1 explicitly
forbids.

## This is the whole fleet, not one store

Across the 22 packs in `openclaw-state-staging/workspace/`, no agent has an
order-writing tool. The ones that close do it with `send_finalize_button`, and
that tool **sends a button that opens the checkout site — payment happens there,
not in the chat** (`agent-store-maria-filo/TOOLS.md:233`). `customer_confirm`
appears nowhere outside this repository.

`create_order` — the tool the bench holds, and the whole subject of the pilot —
exists only in the synthetic bench store.

## The second half does not apply either

The pilot's other half is "clear additions execute immediately". The Natura pack
already does this: a text request or a card click with a quantity goes straight
to `add_to_cart` (`AGENTS.md:160`). It asks only when a card click carries no
quantity — *"NUNCA chute 1"* (`AGENTS.md:75`), a deliberate store decision about
a genuinely missing datum, and the kind of clarification step 1 says to keep.

Note this is the opposite of the bench prompt's rule 5, which now says an unstated
quantity is one unit. The bench is not the store, and the store is right for its
own surface: a tap on a card is not a sentence.

## What the bench work is still good for

The scenario-16 gate (`evals/bench/cuts/2026-09-12-pilot-gate/`) stands on its own
merits: it found and fixed a real prompt defect — the permission question spreading
from the checkout to the addition, 18/20 — and it measured the hold at 20/20 with
no extra round trip. It is evidence about the engine's `customer_confirm`, ready
for the first deployment that actually writes an order from a chat turn.

Steps 2, 3 and 4 of the plan are not blocked on scheduling. They are waiting on a
store that does not exist yet.
