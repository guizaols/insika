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

## Which one is yours?

Two channels ship with the engine, and the choice between them is **where the
conversation happens**.

| | [**web widget**](#the-web-widget) | [**relay**](#the-relay-contract) |
|---|---|---|
| Where people talk to you | a panel on your own site | WhatsApp, Slack, your app — wherever you already are |
| Who talks to that platform | — (there is none) | **you**, with the integration you already have |
| Who runs the turn | the engine | the engine |
| What you have to build | nothing: one `<script>` tag | two HTTP calls |

**The web widget** is for a team with no messaging stack at all. Paste one tag on
your site and you have an agent — no backend of yours, no build step, no npm.

**The relay** is for a team that already owns its messaging stack — a WhatsApp BSP,
a Zendesk, a legacy Rails app with years of tuning in it. You keep every bit of
that. You POST the customer's message to the engine, the engine POSTs the answer
back to a URL you control, and your existing code does what it already does well.
Nothing about your platform integration has to move for you to adopt Insika.

They are not stages of the same path. Plenty of teams run both.

> **On Slack and WhatsApp "natively".** The engine does not speak either platform,
> and that is a decision rather than a gap. If your customers are on WhatsApp or
> Slack, the relay is the answer: you own the platform integration — the 24-hour
> window, templates, media, read receipts, formatting — and the engine owns the
> turn. That boundary is [the promise, not a limitation](#what-the-relay-does-not-do--on-purpose),
> and it is why the relay is permanent rather than a stepping stone.
>
> Adapters that make the engine speak a platform directly are specified and
> deliberately unbuilt. The seam they would plug into is real and proven — the two
> channels above are its opposite shapes, and a third would add `deliver` and
> nothing else — so this is a question of demand, not of design. If you need one,
> [open an issue](https://github.com/guizaols/insika/issues); you can also
> [write it yourself](#writing-your-own-channel) as a plugin, without forking.

## The web widget

For a team with no messaging stack at all: **one `<script>` tag on your site and
you have an agent**. No backend of yours, no build step, no npm.

```html
<script src="https://agents.example.com/channels/web/asset/widget.js"
        data-agent="support" data-title="Ask us anything" defer></script>
```

It renders a bubble in the corner, opens a panel, and streams the answer token by
token on the same connection it sent the message on. Everything it needs it reads
off its own tag — including the engine's address, derived from the script's own
`src`, so you never configure a host twice.

| Attribute | Required | What it does |
|---|---|---|
| `data-agent` | **yes** | which agent answers. Must be on `INSIKA_WIDGET_AGENTS` |
| `data-title` | — | the panel header (default `Chat`) |
| `data-placeholder` | — | the input's placeholder |
| `data-greeting` | — | a first message from the agent, shown without running a turn |

Theming is a block of CSS custom properties. Set them anywhere on the page:

```css
:root {
  --insika-accent: #0f766e;   --insika-on-accent: #fff;
  --insika-bg: #fff;          --insika-fg: #111827;
  --insika-muted: #f0fdfa;    --insika-border: rgba(0,0,0,.12);
  --insika-font: "Inter", system-ui, sans-serif;
  --insika-offset: 20px;      /* distance from the corner */
}
```

A runnable page lives in
[`examples/web-widget/`](https://github.com/guizaols/insika/tree/main/examples/web-widget).

### Setting up the widget

Two environment variables, and **both are the switch** — with either one missing the
channel is not mounted and every `/channels/web/*` route answers `404`:

```bash
INSIKA_WIDGET_ORIGINS=https://shop.example,https://www.shop.example
INSIKA_WIDGET_AGENTS=support
```

`INSIKA_WIDGET_ORIGINS` is an **exact-match** list of the origins allowed to embed
the widget. No wildcards, no subdomain matching, and no value that means "anyone" —
`https://shop.example` does not admit `https://a.shop.example`. Include every origin
your site actually serves from, `www` included.

`INSIKA_WIDGET_AGENTS` is the list of agents a visitor may address. An anonymous
browser addresses these and nothing else, so an internal agent in the same
deployment stays out of reach even if someone edits the `data-agent` in devtools.

### A rate limit is required, not suggested

**The widget answers `503` until a chat rate limit is configured.** This is the one
place the engine refuses to run rather than warn, because a public endpoint with an
LLM behind it and no ceiling is an unmetered bill that arrives before anybody
notices.

Either source satisfies it — the platform default, in Studio → Settings:

```json
{ "edge": { "chat_rate_limit": 6, "chat_rate_window": 60 } }
```

or a per-agent `limits.chat_rate_limit` on **every** agent in
`INSIKA_WIDGET_AGENTS`. The bucket is the minted session id, so one visitor cannot
spend another's allowance. `insika doctor` tells you which half is missing.

### The three routes

You never call these yourself — the widget does — but they are the contract, and
anything can speak them.

```
POST /channels/web/sessions          -> 201 {"session_id": "web:8f3c…"}
POST /channels/web/messages          -> 200 text/event-stream
GET  /channels/web/asset/widget.js   -> the script
```

```jsonc
POST /channels/web/messages
Content-Type: application/json

{ "agent": "support", "session_id": "web:8f3c…", "message": "cadê meu pedido?" }
```

The reply is SSE on that same connection — four frame types, and an unknown one is
safe to ignore:

```
event: delta     data: {"delta":"Seu pedido "}     the answer, token by token
event: working   data: {"name":"order_status"}     a tool is running
event: done      data: {}                          the turn ended
event: error     data: {"message":"…"}             it ended badly
```

**The engine issues the session id and the client never proposes one.** `POST
/messages` with an id nobody minted is a `404`, never a new conversation: on an
anonymous endpoint, create-on-write means anyone who guesses an id can read someone
else's chat. The widget keeps the id it was given in `localStorage`, so a returning
visitor continues the same conversation.

### What the widget does not do

File upload, typing indicators, history across devices, and i18n of its own chrome
(the four words on the buttons). It also never retries a message POST: that request
runs a turn, so re-sending it costs a second LLM call and can put a second answer in
front of the customer. A dropped stream shows what arrived and lets the person ask
again.

## Relay or the drop-in API?

If you already own your messaging platform, you can reach the engine two ways: the
drop-in [`POST /v1/responses`](/architecture/) — you hold an SSE connection for the
whole turn and read the answer off it — or the relay, where the engine acks in
milliseconds and POSTs the answer to you when it exists.

The instinct is that streaming gets the customer their reply sooner, and that the
relay trades that away. **It does not, and the reason is structural:** the engine
publishes `:content` as the ANSWER, whole, after the turn's hooks
([what crosses the edge](/architecture/#what-crosses-the-edge)). During the turn the
stream carries tool activity; the text arrives in one piece at the end. Measured on
a real store agent, the text frames span **0 ms** — there is nothing to deliver
progressively, on either path.

|  | drop-in `/v1/responses` | relay |
|---|---|---|
| What the customer receives | one message, at the end | one message, at the end |
| Your app's request | held open for the whole turn (seconds) | acked in **milliseconds** |
| A turn that outlives your HTTP timeout | your problem | already handled — the answer arrives later |
| Retry on a failed handover | yours to build | the engine's outbox, bounded, at-most-once |
| Three fragments typed in a row | three turns, three replies | **one turn, one reply** (with `queue_mode`) |
| Your platform code | unchanged | unchanged |

That last row is the one that cannot be had the other way. `/v1/responses` answers
the request it was given, so a message that arrives while a turn is running is a
second turn — the engine has no way to tell you "this joined the previous one". The
relay's `merged` / `steered` acks exist precisely to say that, which is why
[the inbound queue](/agents/#queue_mode--when-a-message-arrives-while-the-agent-is-busy)
is only reachable from here.

**Measured, so you can judge it rather than take our word:** same agent, same
conversations, one local deployment.

```
                       drop-in            relay
greeting               2.3s               2.9s   (ack 11ms)
catalog (4 tool calls) 6.8–12.3s          9.4s   (ack  2ms)
3 fragments            3 turns/3 replies  1 turn/1 reply, with queue_mode
```

The spread on the catalog turn is the tool retrying, not the transport — the relay
adds one HTTP POST, not seconds. Your numbers will differ; the *shapes* are what
transfer.

**Pick the drop-in** if you already have it working and none of the rows above bite.
**Pick the relay** if you want the queue, or if holding a connection for the length
of a turn is awkward where your app runs.

## What the relay does not do — on purpose

Platform semantics stay with you:

- the 24-hour customer-service window and template fallback,
- template approval and template sending,
- media upload and download,
- typing indicators and read receipts,
- how a markdown reply becomes WhatsApp formatting.

The engine sends **text and identity**. That is the promise, not the limitation:
it is what lets you keep an integration you have already tuned, and it is why
nothing here expires. A relay that starts growing template logic has stopped being
a relay; the place for platform semantics is the code that already has them —
yours — or a [channel of your own](#writing-your-own-channel).

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
  "vars":        { "store": "demo-store" } // optional — session vars on first contact
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

## Setting up the relay

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

## Shadow mode

Shadow mode (RFC-0025) lets one channel run every turn **end to end and deliver
nothing** — the experiment that answers "can we replace the incumbent?" before
any customer is handed over. The incumbent keeps answering; the engine records
what it *would* have answered, and the two replies are judged pairwise against a
**frozen criterion** (`evals/PARITY.md`).

```bash
INSIKA_RELAY_SHADOW=1    # the switch
# INSIKA_PARITY_CRITERION defaults to evals/PARITY.md
```

Three things change when it is on:

- The turn still runs; the reply is recorded as a **pair** and never reaches the
  customer. Zero outbox records, ever — and `Relay#deliver` refuses loudly if one
  somehow exists.
- The inbound ack becomes `200 {"task_id": …, "shadow": true}` instead of `202`,
  so a consumer wired to "202 means a reply is coming" cannot be misled.
- `event_id` becomes **required** — it is the correlation key both halves of the
  pair are built from.

The incumbent's reply enters the same pair through one of two shapes: alongside
the mirror call itself (`"incumbent_reply": "…"` on `POST /channels/relay/events`),
or as a follow-up when the consumer answers first:

```jsonc
POST /channels/relay/shadow-reply
Authorization: Bearer <INSIKA_RELAY_TOKEN>
{ "external_id": "5511999998888", "event_id": "wamid.HBg…",
  "reply": "Claro! Me passa o número do pedido?", "at": "2026-…Z" }
→ 202 { "pair_id": "9f2c…", "status": "open" }
```

Both shapes land in one command; a retried reply is ignored (first write wins —
the customer received one reply, and a retry must not rewrite evidence).

**No criterion, no shadow.** Boot refuses when shadow is on and
`evals/PARITY.md` is missing or unparseable — a number nobody pre-registered
does not count. The Studio's Parity page folds the running verdict on demand
from the pair store; `insika doctor` reports the shadow configuration before
boot does.

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
and it mounts under `/channels/<id>/`.

Two members are always there; the rest of the object decides which shape you get.

```ruby
class MyChannel
  def id = "mine"

  # -> :ok | :unauthorized | :disabled. Never open by omission — a channel with
  # no `authenticate` at all is refused with 503 rather than defaulted open.
  def authenticate(req) = ...

  # Rack request + parsed body -> the fields the engine turns into a turn.
  def parse(req, body:) = ...
end
```

**Shape B** (the platform calls you back later) adds `deliver`, and that alone
mounts `POST /channels/<id>/events`:

```ruby
  def parse(req, body:)
    { agent: …, external_id: …, message: …, event_id: …, vars: {} }
  end

  def session_id_for(external_id) = "#{id}:#{external_id}"

  # Hand ONE reply to the platform. -> HTTP status.
  # Raise Insika::DeliveryError when the request could not be made at all.
  def deliver(payload, to:, delivery_id: nil) = ...
```

**Shape A** (the reply rides the request's own connection) adds `frame_for`, which
mounts `POST /channels/<id>/messages`, plus whichever of these it wants:

```ruby
  def parse(req, body:) = { agent: …, session_id: …, message: … }

  # Turn Event -> an SSE frame | nil for an event with no counterpart.
  def frame_for(event) = ...

  # Optional: mounts POST /channels/<id>/sessions. The engine issues the id.
  def mint_session_id = "#{id}:#{SecureRandom.hex(16)}"

  # Optional: mounts GET /channels/<id>/asset/:f. A CLOSED map of names, never a
  # path — anything resolving a filesystem path from a URL is a traversal.
  def asset(name) = { content_type: …, body: …, etag: …, cache_control: … }

  # Optional: the CORS headers for this origin, or none.
  def cors_headers(origin) = ...
```

Everything else is shared — the outbox, the at-most-once claim, the bounded retry,
the inbound dedup and the queue. A channel that needs to branch anywhere but
`deliver` is a sign the seam is wrong, not that the channel is special.

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
