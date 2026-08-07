---
title: Channels
parent: Build an agent
nav_order: 6
permalink: /channels/
---

# Channels

An agent is only useful where the people are. A **channel** is the seam between a
place people already talk — WhatsApp, Slack, a widget on your site, your own app —
and a turn of the engine.

A channel does exactly two things:

- **inbound**: normalize whatever the platform sent into a message for an agent;
- **outbound**: render the turn's answer back in that platform's shape.

Nothing else. A channel never decides which tools an agent may call, never edits a
prompt, never grants a capability. It may *refuse* a request (a bad signature); it
may not *widen* one. Everything a channel learns about the caller is data, and it
enters the prompt at the most cuttable priority, like any other untrusted input.

## Which shape is yours?

This is the only decision you have to make, and it is about **who owns the
platform**, not about how big you are.

|  | **native** | **relay** |
|---|---|---|
| Who talks to WhatsApp/Slack/… | the engine | **you** |
| Who runs the turn | the engine | the engine |
| You already have a messaging integration | — | **yes** |
| You have none and want one | **yes** | — |

**Relay** is for the team that already owns its messaging stack — a WhatsApp BSP,
a Zendesk, a legacy Rails app with years of tuning in it. You keep every bit of
that. You POST the customer's message to the engine, the engine POSTs the answer
back to a URL you control, and your existing code does what it already does well.
Nothing about your platform integration has to move for you to adopt Insika.

**Native** is for the team with no messaging stack, who wants the engine to *be*
the integration.

Both are permanent. Relay is not a migration step, and there is no point at which
you are expected to "graduate" to native.

> **Available today: the relay.** The web widget, Slack and native WhatsApp are
> specified (RFC-0011) and not built. This page documents what exists.

## What the relay does not do — on purpose

Platform semantics stay with you:

- the 24-hour customer-service window and template fallback,
- template approval and template sending,
- media upload and download,
- typing indicators and read receipts,
- how a markdown reply becomes WhatsApp formatting.

The engine sends **text and identity**. That is the promise, not the limitation:
it is what lets you keep an integration you have already tuned. A relay that
starts growing template logic has stopped being a relay — if you want the engine
to own all of that, you want a native channel.

## The relay contract

Two routes and an envelope.

```
you ──POST /channels/relay/events──▶ engine     acked now, never the reply
you ◀──POST <your deliver_url>───── engine      the reply, when there is one
```

### Inbound

```jsonc
POST /channels/relay/events
Authorization: Bearer <INSIKA_RELAY_TOKEN>
Content-Type: application/json

{
  "agent":       "support",              // required — which agent answers
  "external_id": "5511999998888",        // required — YOUR key for this conversation
  "message":     "queria saber do pedido", // required
  "event_id":    "wamid.HBg…",           // optional but strongly recommended (dedup)
  "vars":        { "store": "ocean-drop" } // optional — session vars on first contact
}
```

The engine acks immediately and never streams the answer here. Four possible
answers, and **they are four different facts**:

| Status | Body | What happened | What you must do |
|---|---|---|---|
| `202` | `{"task_id": "…"}` | a turn is running | wait for the delivery |
| `200` | `{"task_id": "…", "duplicate": true}` | we already ran this `event_id` | nothing — the original reply is on its way |
| `200` | `{"task_id": "…", "merged": true}` | it joined a turn still at the door | nothing — the answer belongs to `task_id` |
| `200` | `{"task_id": "…", "steered": true}` | it was appended to a turn already running | nothing — same |
| `422` | `{"error": …}` | the envelope is malformed | fix and resend |
| `401` / `503` | `{"error": …}` | bad token / channel not configured | fix the credential |

**A consumer that treats the three `200`s like a `202` sends the customer the same
answer two or three times.** That is the one contract mistake that is visible to
the end user, so it is worth a line of code: only deliver for a `202`.

`merged` and `steered` come from the [inbound queue](/agents/#queue_mode--when-a-message-arrives-while-the-agent-is-busy)
(`limits[:queue_mode]`). They only ever occur if you turned that on for the agent;
with the default `followup` you will only see `202` and `duplicate`.

### Outbound

One POST per reply, to the URL you configured:

```jsonc
POST <INSIKA_RELAY_DELIVER_URL>
Authorization: Bearer <INSIKA_RELAY_DELIVER_TOKEN>   // omitted if unset
X-Insika-Delivery: 0f2c…                              // stable idempotency key
Content-Type: application/json

{
  "external_id": "5511999998888",
  "session_id":  "relay:5511999998888",
  "task_id":     "…",
  "content":     "Seu pedido saiu para entrega hoje 😊"
}
```

Any `2xx` means delivered. Anything else is retried, up to three attempts with a
short backoff, and then the delivery is marked `failed` and stops.

`content` is the turn's **answer** — one message, whole. The model's narration on
the way to an answer ("vou verificar o cardápio…") does not come through here; it
stays internal unless the agent opts in. That contract is
[the edge contract](/architecture/#what-crosses-the-edge), and it is why you can
forward `content` straight to the customer.

### Deduplication

Send `event_id` and a retried webhook costs you nothing: the engine recognizes the
id inside a 24-hour window, answers `duplicate: true`, and runs no turn. Without
it, every retry on your side is a second LLM turn (that you pay for) and a second
message (that the customer reads).

The engine will not invent dedup from a content hash — two customers typing "oi"
a second apart are not a duplicate. No `event_id` means at-least-once turns, and
that is stated rather than hidden.

### Delivery guarantee: at-most-once

The reply is written durably when the turn commits, then **claimed** before the
HTTP call. If the process dies between the claim and the POST, that delivery is
lost; it is never duplicated. On boot, replies that were recorded but never
claimed are re-dispatched.

This is deliberate and it is the same guarantee the engine's async-subagent
delivery has. If you need at-least-once instead, the honest place to build it is
your side: you already have the customer's conversation, and `GET /v1/tasks/:id`
tells you the turn's terminal state.

A turn that **failed** delivers nothing — an error string is not an answer. Watch
`GET /v1/tasks/:id` or the [event stream](/observability/) for those.

## Setting it up

Three environment variables on the engine:

```bash
INSIKA_RELAY_TOKEN=<a long random secret>       # the switch AND the credential
INSIKA_RELAY_DELIVER_URL=https://you.example/insika/deliver
INSIKA_RELAY_DELIVER_TOKEN=<another secret>     # optional; what we send to you
```

`INSIKA_RELAY_TOKEN` is the switch: without it the channel is not mounted and
`/channels/relay/events` answers `404`. There is no way to expose this route
without a credential — a public inbound route with an LLM behind it is a money
faucet, so it fails closed by construction.

The delivery POST goes through the same [egress guard](/security/#egress-the-ssrf-boundary) as
data-tools: **https only**, and private/loopback destinations blocked. For local
development, where your consumer is on `localhost`:

```bash
INSIKA_EGRESS_ALLOW_HTTP=1
INSIKA_EGRESS_ALLOW_PRIVATE=1
```

Run `insika doctor` after configuring — it refuses to let you have half of it
(a token with no URL accepts turns it can never answer; a URL with no token mounts
nothing at all).

A runnable consumer in ~40 lines lives in
[`examples/relay-channel/`](https://github.com/guizaols/insika/tree/main/examples/relay-channel).

## Sessions

The engine mints the session id: `relay:<your external_id>`. Namespacing is not
decoration — it stops a Slack channel id from colliding with a phone number, and
it means an id from one channel can never read another channel's conversation.

Your `vars` ride along on first contact and become session vars, except for
`channel` and `external_id`, which the engine always owns. A caller cannot
redirect its own conversation.

## Writing your own channel

A channel is a plain object — no base class. Register it from a plugin
(see [Plugins](/plugins/)) with `contracts: { channels: [<id>] }` in the manifest,
and it mounts at `/channels/<id>/events`.

```ruby
class MyChannel
  def id = "mine"

  # -> :ok | :unauthorized | :disabled. Never open by omission.
  def authenticate(req) = ...

  # Rack request + parsed body -> the fields the engine turns into a turn.
  def parse(req, body:)
    { agent: …, external_id: …, message: …, event_id: …, vars: {} }
  end

  def session_id_for(external_id) = "#{id}:#{external_id}"

  # Shape B only: hand ONE reply to the platform. -> HTTP status.
  # Raise Insika::DeliveryError when the request could not be made at all.
  def deliver(payload, to:, delivery_id: nil) = ...
end
```

Everything except `deliver` is shared: the outbox, the at-most-once claim, the
bounded retry, the inbound dedup and the queue. A channel that needs to branch
anywhere else is a sign the seam is wrong, not that the channel is special.

## Observability

Each delivery emits `:channel_delivered` on the event stream —
`{channel, outbox_id, status, attempts, error}` — so a failed handover is visible
without reading the store. Inbound is already visible: the turn's persisted
command carries `transport: "channel:<id>"`.

## See also

- [Security](/security/) — the tokens, the egress guard, and why the rate limit
  matters for anything public.
- [Agents](/agents/) — `limits[:queue_mode]`, which is what produces `merged` and
  `steered`.
- [Observability](/observability/) — the event stream and OpenTelemetry.
