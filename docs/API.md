---
title: The /v1 API
parent: Integrate
nav_order: 1
permalink: /api/
---

# The /v1 API — the frozen compatibility contract

The HTTP surface is the drop-in OpenAI-Responses-compatible contract: a client
that speaks `/v1` today speaks it tomorrow. This page is the WRITTEN promise
— the mechanical half is the version gate in the server, and the
two cannot drift (a spec pins the gate's version to the date below).

## The surface

| Route | What it is |
|-------|------------|
| `POST /v1/responses` | the OpenAI-Responses-compatible turn ingress (streaming SSE) |
| `POST /v1/messages` | the channel-style message ingress (one turn per message, ack-fast) |
| `POST /v1/agents` | provisioning by definition/pack (idempotent, authoritative) |
| `GET/DELETE /v1/agents` | list / remove agents |
| `POST /v1/sessions` | create a session explicitly |
| `POST /v1/conversations/:id/seed` | load an eval snapshot before the first turn; see [Seeding](#seeding-an-eval-conversation) |
| `POST /v1/outcomes` | record a business outcome (`conversion`, `escalation`, any label) |
| `GET /v1/outcomes` | last outcome per agent + the per-day series |
| `POST /v1/commands/...` | operator commands (`forget_customer`, `delete_tenant_data`, the follow-up mutations) |
| `GET /v1/vitals` | process health/uptime vitals |
| `GET /v1/...` | the onboarding surface (`start.md`, `models.json`, `/docs/<name>.md`) |

The turn endpoints speak the OpenAI `response.completed` wire format; the
`Insika-Version` header declares the compatibility vintage of a request.

## Tool and presentation SSE events

`POST /v1/responses` emits a tool name on `response.output_item.added`, with
`arguments` as a JSON string when available. `response.output_item.done` reports
how it ended. These `ok` / `error` / `blocked` statuses and optional `gate` are
Insika extensions, not OpenAI function-call lifecycle statuses.

```text
event: response.output_item.added
data: {"type":"response.output_item.added","item":{"type":"function_call","name":"add_to_cart","call_id":"toolu_01","arguments":"{\"product_id\":\"SKU-1\"}"}}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","name":"add_to_cart","call_id":"toolu_01","status":"blocked","gate":"provenance"}}
```

`added` and `done` are two frames of **one** call, paired by `call_id` (the provider's
tool-call id, present whenever the provider gave one). A consumer that counts tool
calls counts `added` frames; `done` only says how each ended.

The completion frame does not contain the tool result body. Use stored session
traces for a per-call audit of what a tool returned.

A presentation call also emits a namespaced event:

```text
event: insika.ui
data: {"type":"insika.ui","component":"product_cards","title":"Selected products","items":[{"type":"card","id":"SKU-1","url":"https://shop.example/products/1","caption":"Dark chocolate"}],"count":1,"dropped":[{"id":"SKU-2","reason":"no_card"}]}
```

`count` is the number shown; `dropped` reasons are `unknown`, `no_card` or `max`.
An empty selection still emits the event with `count: 0`. Clients that render
cards consume this event; text-only clients can ignore it. See
[Presentation tools](TOOLS.md#presentation-tools-the-model-picks-ids-the-engine-shows-the-cards).

## Seeding an eval conversation

Enable `evals.seeding` in platform settings on the eval deployment. For example,
an operator can `POST /v1/commands/update_settings` with
`{"patch":{"evals":{"seeding":true}}}`. Turn it off after the run.

`POST /v1/conversations/:id/seed` uses the same Bearer and tenant ID namespacing
as a turn. Its body is the snapshot itself, plus optional `customer`; do not wrap
it in `state`:

```json
{
  "customer": "eval-customer-1",
  "evidence": {
    "ids": ["SKU-1"],
    "cards": [{ "type": "card", "id": "SKU-1", "url": "https://shop.example/1", "caption": "Dark chocolate" }]
  },
  "history": [
    { "role": "assistant", "content": "The dark chocolate is SKU-1." }
  ],
  "memory": { "facts": { "preference": "dark chocolate" }, "notes": [] },
  "briefing": { "fields": { "delivery_day": "Friday" } }
}
```

It creates a missing session and returns `200` with `{ "session": … }`; seeding
does not run a model or create a task. Disabled seeding returns `403`, a session
with messages returns `409`, and invalid supported field shapes return `422`.
History accepts only `user` / `assistant` roles and is stamped `origin: engine`.

Memory uses `[tenant:]customer` when `customer` is supplied; subsequent turns
must carry the same customer. Without one, memory is written to the tenant cell,
or `chat:<session-id>` when there is no tenant. Use an isolated eval deployment:
a fresh conversation ID alone does not isolate tenant memory. Evidence IDs seed
only the runtime ledger, never model-visible text; `evidence.cards` seeds the cards
a presentation tool can show.
See [Snapshot evals](EVALS.md#state--a-case-starts-from-a-snapshot).

## The compatibility rule

**Request and response shapes are stable; changes are additive-only.** A new
field on a request or response is a release. Removing, renaming or re-typing a
field is a BREAKING change and requires, together, all three:

1. a new `Insika-Version` entry in the server's known-versions gate (an
   unknown value is refused with 400 before auth — fail-closed);
2. a route branch that serves both vintages (a compatibility branch), so
   an old client keeps working while the new shape rolls;
3. a new `**Frozen as of:**` line below.

Additive changes need none of the three.

**Frozen as of: 2026-08-08** — the date that is the 1.0 promise. The gate's
first known version, pinned by `spec/insika/server/version_gate_spec.rb`; the
release writes the 1.0 freeze date here at release time.

## The 400-on-unknown rule

A request carrying an `Insika-Version` the gate does not know is refused with
`400 Bad Request` BEFORE authentication — a client that speaks a future or
misspelled vintage learns immediately, and an unauthenticated probe cannot
distinguish the gate from auth (fail-closed, constant-time).
