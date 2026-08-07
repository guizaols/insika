# relay-channel

**Bring your own platform.** You already have WhatsApp (or Slack, or your own app)
working. You want the engine for the *turn*, not for the platform. That is the
**relay**: two routes and an envelope, and none of your integration has to move.

```
you ──POST /channels/relay/events──▶ engine     acked now, never the reply
you ◀──POST <your deliver_url>───── engine      the reply, when there is one
```

Full contract: [docs/CHANNELS.md](../../docs/CHANNELS.md).

## Run both sides

Three terminals, no accounts, no tunnels.

**1 — your callback** (this example plays the part of your messaging stack):

```bash
bundle exec falcon serve --bind http://127.0.0.1:4000 \
  --config examples/relay-channel/consumer.ru
```

**2 — the engine, with the relay turned on:**

```bash
export INSIKA_RELAY_TOKEN=dev-inbound-secret
export INSIKA_RELAY_DELIVER_URL=http://127.0.0.1:4000
export INSIKA_EGRESS_ALLOW_HTTP=1 INSIKA_EGRESS_ALLOW_PRIVATE=1  # localhost callback
export DEEPSEEK_API_KEY=sk-...

ruby examples/relay-channel/support_agent.rb
```

The banner lists `/channels/relay` when the channel is mounted. If it does not, the
token is missing — that variable is the switch, and without it the route is a `404`
rather than an open endpoint.

> `INSIKA_EGRESS_ALLOW_HTTP` / `_ALLOW_PRIVATE` are here **only** because your
> callback is on `localhost`. The delivery POST goes through the same SSRF guard as
> data-tools; in production your callback is https on a public host and neither flag
> belongs in the environment.

**3 — send a message as the platform would:**

```bash
INSIKA_RELAY_TOKEN=dev-inbound-secret ruby examples/relay-channel/send.rb "cadê meu pedido 1234567?"
```

Terminal 3 prints the ack; a second later, terminal 1 prints the delivery.

## The one thing to get right

The ack tells you **who owns the reply**:

| Ack | Meaning | You deliver |
|---|---|---|
| `202 {task_id}` | a turn is running for this message | **yes**, when it arrives |
| `200 {task_id, duplicate}` | we already ran this `event_id` | no |
| `200 {task_id, merged}` | it joined a turn still at the door | no |
| `200 {task_id, steered}` | it was appended to a turn already running | no |

A consumer that treats the `200`s like a `202` sends the customer the same answer
twice. Try it: run `send.rb` twice with the same `EVENT_ID=abc` and watch the second
call come back `duplicate` — one turn, one delivery.

## Files

| File | What it plays |
|---|---|
| `support_agent.rb` | the engine: one ordinary agent, served |
| `consumer.ru` | your side's callback — prints what it would have sent |
| `send.rb` | your side's inbound POST, with the ack table spelled out |
