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
| `POST /v1/outcomes` | record a business outcome (`conversion`, `escalation`, any label) |
| `GET /v1/outcomes` | last outcome per agent + the per-day series |
| `POST /v1/commands/...` | operator commands (`forget_customer`, `delete_tenant_data`, the follow-up mutations) |
| `GET /v1/vitals` | process health/uptime vitals |
| `GET /v1/...` | the onboarding surface (`start.md`, `models.json`, `/docs/<name>.md`) |

The turn endpoints speak the OpenAI `response.completed` wire format; the
`Insika-Version` header declares the compatibility vintage of a request.

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
