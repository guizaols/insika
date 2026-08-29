---
title: Router
parent: Ship it
nav_order: 4
permalink: /router/
---

# Session-sticky router

`insika-router` is a standalone proxy that lets you run **N engine backends**
(`WEB_CONCURRENCY=1` each) and get the same per-session guarantees a single
worker gives you today — FIFO ordering, `collect`/`steer`, the SSE watch (see
[DEPLOY.md "The process model"](DEPLOY.md#the-process-model)) — at N>1
capacity. It is **entirely opt-in**: if one worker is enough for you, ignore
this file, run the engine exactly as DEPLOY.md already describes, and nothing
changes. Reach for the router only when you outgrow one worker and want to
scale up.

It changes nothing about the engine itself — no code in `SessionActor` or
`Executor` is aware the router exists. It solves routing, and routing only: a
given session's requests always land on the same backend, so that backend's
in-memory session state is always the one being read and written.

## Why this exists

`WEB_CONCURRENCY>1` without sticky routing in front is not "reduced
guarantees" — it is a correctness bug (a reply from one session can leak into
another's transcript; `insika doctor`'s `web-concurrency` check exists because
this happened in staging). Sticky routing is the documented escape hatch, but
neither deploy target the engine ships for has it built in:

- **Railway** does not support sticky sessions at all — traffic is randomly
  distributed across replicas, with no configuration that changes that.
- **Kubernetes** `Service` load-balances with no session notion, and
  ingress-nginx's `upstream-hash-by` (the usual sticky mechanism) hashes on
  nginx *variables* — headers, cookies, the URL — never a field parsed out of
  a POST body. The session id here is exactly that: the `user` field inside
  `POST /v1/responses`'s JSON body.

So this is a small piece of new infrastructure, not a config flag.

## How it decides where a request goes

Per request, in order:

1. `GET /up` → answered directly by the router (its own liveness), never
   proxied.
2. `POST /v1/responses` or `POST /v1/messages` → the session key is the
   `user` field of the JSON body.
3. `POST /channels/:id/messages` or `POST /channels/:id/events` (the web
   widget and the relay channel) → the session key is the `session_id` field
   of the JSON body.
4. Everything else (health checks, `/studio/*`, onboarding, minting a new
   channel session) → no session key, plain round-robin. None of these depend
   on a worker's in-memory `SessionActor` — a Studio read hits the durable
   store, and minting a session has no existing state to be sticky about.

A request with a session key is routed by a ketama-style **consistent hash
ring** over the backend list: the same key always reaches the same backend,
and adding or removing one backend remaps only ~1/N of the key space, not the
whole ring — a rolling deploy does not bounce every live session to a new
owner at once. A request whose key isn't found (a corner-case route) or whose
key extraction is skipped (see body size cap below) round-robins across all
backends.

The whole request body is always read and forwarded byte-for-byte —
`INSIKA_ROUTER_BODY_MAX_BYTES` (default 256 KiB) only bounds how much of it
the router will attempt to parse as JSON while looking for a session key; a
body over that cap round-robins instead of erroring, and the router logs it.

**A request whose chosen backend is unreachable is never retried against a
different backend** — that backend may already hold a durable, at-most-once
claim on the task the request names, and retrying elsewhere could
double-process it. It answers the same retry envelope a single overloaded
backend would:

```json
{"error": {"class": "Insika::Router::BackendUnavailable", "message": "no backend reachable",
           "retryable": true, "retry_after": 1}}
```

SSE responses stream through the router with no added buffering — a client
watching a long turn sees the same chunks, in the same order, as if it had
hit the backend directly.

## Deploy shape 1 — Railway (N local workers, one replica)

Railway's replica load balancer has no sticky option, full stop — this shape
does not attempt to fix that. What it fixes is the *unsafe* alternative
(`WEB_CONCURRENCY=N` Falcon workers behind Railway's own port, which is
exactly the leak `insika doctor` errors on). Instead, run N engine processes
on different local ports and put the router in front of them, all inside the
one container Railway load-balances to:

```bash
# three engine workers, WEB_CONCURRENCY=1 each (the entrypoint's own
# `falcon serve --count 1`), on different local ports — never `--count 3` on
# one port, which is exactly the unsafe fan-out this replaces
bundle exec falcon serve --bind http://127.0.0.1:9292 --count 1 config.ru &
bundle exec falcon serve --bind http://127.0.0.1:9293 --count 1 config.ru &
bundle exec falcon serve --bind http://127.0.0.1:9294 --count 1 config.ru &

# the router, bound to the port Railway actually forwards
INSIKA_ROUTER_PORT=$PORT \
INSIKA_ROUTER_BACKENDS=http://127.0.0.1:9292,http://127.0.0.1:9293,http://127.0.0.1:9294 \
  bundle exec insika-router
```

`insika doctor` treats `WEB_CONCURRENCY>1` as `ok` (not `error`/`warn`) once
it sees `INSIKA_ROUTER_BACKENDS` or `INSIKA_ROUTER_BACKENDS_DNS` set — it
cannot verify a router process is actually running at those addresses, only
that one was configured, same as every other env-based capability check in
`insika doctor`.

## Deploy shape 2 — Kubernetes (a headless Service)

Run N engine pods (`WEB_CONCURRENCY=1` each) behind a **headless** Service
(`clusterIP: None` — this is what makes DNS resolve to one A/AAAA record per
ready pod instead of a single virtual IP), and the router as its own
Deployment in front:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: insika-headless
spec:
  clusterIP: None
  selector: { app: insika }
  ports: [{ port: 9292 }]
---
# insika-router Deployment env:
env:
  - name: INSIKA_ROUTER_BACKENDS_DNS
    value: insika-headless.default.svc.cluster.local
  - name: INSIKA_ROUTER_BACKEND_PORT
    value: "9292"
  - name: INSIKA_ROUTER_DNS_INTERVAL
    value: "15"
```

The router holds no session state itself, so it needs no sticky routing in
front of *itself* — it scales trivially (1-2 replicas behind an ordinary
`Service`). It re-resolves the headless Service on `INSIKA_ROUTER_DNS_INTERVAL`
(default 15s) and rebuilds its hash ring only when the resolved pod set
actually changed. A pod that just became ready is invisible to the router
until the next resolve — capacity added a few seconds late, never wrong.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `INSIKA_ROUTER_BACKENDS` | — | Comma-separated backend URLs (static mode). Exactly one of this or the DNS var below. |
| `INSIKA_ROUTER_BACKENDS_DNS` | — | A headless-Service hostname to re-resolve (DNS mode). Requires `INSIKA_ROUTER_BACKEND_PORT`. |
| `INSIKA_ROUTER_BACKEND_PORT` | — | The engine port on every DNS-resolved pod. |
| `INSIKA_ROUTER_DNS_INTERVAL` | `15` | Seconds between DNS re-resolves. |
| `INSIKA_ROUTER_BODY_MAX_BYTES` | `262144` | Size cap on the session-key JSON peek (never on what is forwarded). |
| `INSIKA_ROUTER_BACKEND_TIMEOUT` | `10` | Connect/read timeout to a backend, in seconds. |
| `INSIKA_ROUTER_HOST` | `0.0.0.0` | Bind address for the router itself. |
| `INSIKA_ROUTER_PORT` | `9090` | Listen port for the router itself. |

## A runnable smoke test

The shape below is what the router's acceptance criteria were verified
against: two fake backends and the router in front, run entirely in-process.

```ruby
require "async"; require "async/http/server"; require "async/http/client"
require "async/http/endpoint"; require "protocol/rack"; require "insika/router"

Async do |task|
  echo = ->(name) { ->(env) { [200, {}, ["#{name} #{Rack::Request.new(env).path_info}"]] } }
  %w[9292 9293].each_with_index do |port, i|
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
    task.async { Async::HTTP::Server.new(Protocol::Rack::Adapter.new(echo["backend-#{i}"]), endpoint).run }
  end
  task.sleep(0.2)

  pool = Insika::Router::BackendPool.new(static: %w[http://127.0.0.1:9292 http://127.0.0.1:9293])
  app = Insika::Router::App.new(pool: pool)
  endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:9090")
  task.async { Async::HTTP::Server.new(Protocol::Rack::Adapter.new(app), endpoint).run }
  task.sleep(0.2)

  client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://127.0.0.1:9090"))
  3.times { |i| puts client.post("/v1/responses", {}, [%({"user":"sess-1","i":#{i}})]).read }
  # -> the same "backend-N" answers all three times, even though two backends are up.
ensure
  task.stop
end
```

## What this deliberately does not attempt

- **Railway cross-*replica* routing.** Railway's replica load balancer itself
  has no sticky option and this router cannot sit in front of Railway's own
  edge. Railway stays at one replica; this only raises the ceiling of that one
  replica (N local workers instead of N=1).
- **A distributed `SessionActor`.** The alternative design — making any
  worker able to safely pick up any session, removing the need for sticky
  routing entirely — is a much larger rewrite (debounce windows, steer
  mailboxes, and SSE fan-out would all have to move into the shared store with
  lease semantics) for the same outcome this router reaches with an unchanged
  engine. Worth revisiting only if this approach turns out not to scale far
  enough.
- Native WhatsApp/Slack channel routing — those channels are shelved; the
  relay channel rides the same `/v1/responses`-shaped call this router already
  covers.

## See also

- [DEPLOY.md "The process model"](DEPLOY.md#the-process-model) — the contract
  this router satisfies (FIFO/`collect`/`steer` guarantees, recovery, drain).
