---
title: Security
parent: Ship it
nav_order: 1
permalink: /security/
---

# Security

An agent runtime runs untrusted input through a model that can call tools and
touch the outside world. Insika treats that as the core problem, not an add-on.
Every control below is **built into the engine**, **configured as data** (not
hand-rolled per agent), and composes with the others. This page is the map;
each section links to the deeper guide.

The layers, from the edge inward:

0. **[The Bearer gate](#the-bearer-gate)** — nothing but the health probe answers without a token.
1. **[Edge limits](#edge-limits)** — stop a flood before it costs anything.
2. **[Input guardrails](#guardrails)** — refuse injection/abuse without a model turn.
3. **[Human approval](#human-approval)** — gate high-risk tool calls on an operator.
4. **[Egress guard](#egress-the-ssrf-boundary)** — bound where a tool can reach.
5. **[Sandbox](#sandbox-confined-execution)** — bound where code can run.
6. **[Output guardrails](#guardrails)** — moderate and redact what streams back.
7. **[Secrets](#secrets-live-only-in-the-environment)** — never on disk, never in the model.

## The Bearer gate

The `/v1` and `/a2a` surface answers only with
`Authorization: Bearer <OPENCLAW_GATEWAY_TOKEN>` (which falls back to `ADMIN_TOKEN`).
The check runs in the router, **before** any dispatch, against an **allowlist** of
public routes — so a route added later is closed until someone deliberately publishes
it. Only these answer without a token:

| Route | Why |
|---|---|
| `GET /up` | health/readiness probe; touches no store |
| `GET /start.md`, `/models.json`, `/docs`, `/docs/<name>.md` | the onboarding surface, opt-in via `INSIKA_ONBOARDING`: it exists to be read by a coding agent that has no credential yet |
| `GET /.well-known/agent-card.json` | A2A discovery — the card is the advertisement |

**With no token configured, the surface is not open — it is `503`.** Fail-closed by
construction, the same posture as `/studio`, which denies login without `ADMIN_TOKEN`.
`insika doctor` warns when neither is set.

This matters most for `POST /v1/commands/<type>`, the generic Command ingress: it can
dispatch **any** registered authoring Command (`write_agent_file`, `write_data_tool`,
`upsert_llm_provider`, `update_settings`, `delete_agent`). Treat that token as
operator-grade — it is not a read key, and a leak is agent takeover, not just usage.

## Channels authenticate themselves

`/channels/<id>/…` is the one route family that does **not** answer to the gateway
token — and it is not an exception to the rule above, it is the same rule with a
different credential. A messaging platform has no way to send your gateway token,
and neither has a visitor's browser; what they can send is their own scheme (a
shared secret for the [relay](CHANNELS.md), an origin for the widget, an HMAC
signature for a channel you write yourself). So the channel does the check, and the router refuses before
parsing anything:

| The channel says | The route answers |
|---|---|
| `:ok` | the turn is dispatched |
| `:unauthorized` | `401` |
| `:disabled` — no credential configured | `503` |
| the channel has no `authenticate` at all | `503` |

There is no path to an open channel route. A relay with no `INSIKA_RELAY_TOKEN` is
not mounted at all (`404`); one that is mounted always has a secret. That is
deliberate: a public inbound route with an LLM behind it is a money faucet, and
[edge limits](#edge-limits) are the second line, not the first.

The routes are enumerated in the router, not prefix-matched, so a channel route
added tomorrow is gated by default and publishing it is a deliberate edit.

Two more things a relay operator owns:

- **The callback URL is egress.** The delivery POST goes through the
  [egress guard](#egress-the-ssrf-boundary) on every call, not once at boot — a
  hostname that resolved publicly yesterday can resolve to `169.254.169.254`
  today, and that POST carries a customer's conversation.
- **`event_id` is a safety property, not an optimization.** Without it a retried
  webhook is a second turn you pay for and a second message the customer reads.

### A public channel: the web widget

The [widget](CHANNELS.md#the-web-widget) is different from every other surface here
in one way that changes the whole posture: **the caller is an anonymous browser, so
there is no secret to check.** Three controls stand in for the missing credential,
and it is worth being precise about which of them is actually load-bearing.

- **The rate limit is the real defense, and it is mandatory.** The widget answers
  `503` until a chat rate limit exists — the platform's `edge.chat_rate_limit` or a
  per-agent `limits.chat_rate_limit` on every published agent. This is the only
  place in the engine that refuses to serve rather than warn, because the failure
  mode is a bill rather than an error. The bucket is the minted session id, and it
  is checked *before* the input guardrail so a flood cannot even spend the
  moderator. See [edge limits](#edge-limits).
- **The agent allowlist is a real boundary.** `INSIKA_WIDGET_AGENTS` is what an
  anonymous visitor may address. Editing `data-agent` in devtools to name an
  internal agent gets a `422`, not that agent.
- **The origin allowlist is a browser courtesy, not a control.** `Access-Control-
  Allow-Origin` is enforced by the browser, and curl sends whatever origin it
  likes. It stops another *site* from embedding your widget; it does not stop a
  script. Configure it (exact match, no wildcards — `https://shop.example` does not
  admit `https://a.shop.example`) and then do not count on it.

Two more properties worth knowing:

- **The engine issues session ids; the client never proposes one.** `POST
  /channels/web/messages` with an unminted id is a `404`. Create-on-write on an
  anonymous endpoint means anyone who guesses an id joins someone else's
  conversation, and the ids are 128 random bits for the same reason. A session also
  belongs to exactly one channel — a widget visitor cannot stream a relay
  customer's conversation by pasting its id.
- **What the visitor types is data, at the most cuttable priority.** Untrusted
  input from a public channel enters at `REQUEST` (40) like any other turn content,
  and the [guardrails](#guardrails) run before the model. A channel may refuse a
  request; it can never widen what the agent is allowed to do.

## Edge limits

The next gate. The edge limiter wraps a turn **before** the input guardrail,
so a flood cannot even spend an LLM moderator call. Two independent, opt-in
ceilings (nil/0 = off):

- **`chat_rate_limit`** — turn attempts per session per `chat_rate_window`.
  Counted on entry (blocked attempts still count). Keyed by session id, so id
  rotation defeats the per-session limit — the per-agent token ceiling is the
  backstop.
- **`agent_token_ceiling`** — total tokens per agent per `agent_token_window`.
  Checked on entry against a ledger, recorded after the turn. Advisory under
  concurrency (overshoot ≈ in-flight turns).

On breach: a graceful halt returning a configurable `limit_response` with **zero
LLM calls**. A *resumed* turn is never re-counted.

> ⚠️ Windows live at the platform level; the token window defaults to **86400
> (daily)**. "500k tokens per hour" means `agent_token_ceiling = 500000` **and**
> `agent_token_window = 3600`. A per-agent ceiling that is *present but nil* reads
> as OFF for that agent — leave the key **absent** to inherit the platform value,
> `0` to explicitly disable. A malformed value in the Studio raises a validation
> error rather than silently disabling a production limit.

See [Agents §Layer 4](AGENTS.md#layer-4-edge-limits-flood-and-spend-control).

## Guardrails

Content safety runs on both sides of a turn, **opt-in per agent**. An agent that
configures nothing gets a conservative default: deterministic detectors on, LLM
moderator off. See [`examples/guardrails/`](https://github.com/guizaols/insika/tree/main/examples/guardrails/).

- **Input** — deterministic detectors (prompt-injection, abuse) run *before* the
  model. A flagged input gets a **safe refusal without burning a model turn** — an
  injection or a flood never reaches the provider. An LLM moderator can be layered
  on top.
- **Output** — moderation plus PII/secret redaction on the streamed response, and
  a post-turn validator.

```jsonc
{
  "input":  true,
  "output": true,
  "moderator": "provider/model",     // optional LLM moderator; omit for detectors only
  "strictness": "low | medium | high",
  "responses": { "injection": "safe reply…", "default": "…" }
}
```

Strictness selects the detector categories (`low` = injection only; `medium`
(default) and `high` add sexual and abuse). Safe-reply lookup falls back per
category: the agent's category reply → the agent's default → the builtin
category → the builtin default. All of it is editable in the Studio Configuration
form. See [Agents §Layer 3](AGENTS.md#layer-3-guardrails-content-safety).

## Human approval

Some tool calls should not happen unattended. Mark them with
`approvals_required: [tool names]`: the approval policy *tags* those tools, and
when the model tries to call one, the turn **suspends** and waits for an operator
to approve or reject it in the Studio. Approval and confinement are independent
and compose — approval bounds *whether* a tool acts; the sandbox bounds *where* it
can act.

The wait is bounded by `approval_timeout` (default ~1h), and a turn that is
waiting on approval is *not* killed by the ordinary turn timeout. The suspend/
resume path is durable: an approval that arrives after a restart still resumes the
turn from its checkpoint (see
[Architecture](ARCHITECTURE.md#durability-checkpoints-and-resume)).

## Egress: the SSRF boundary

Every outbound HTTP call from a data tool passes through the **EgressGuard**, a
Server-Side Request Forgery defense. The default posture is **strict: public
`https` only** — private and loopback addresses and plain `http` are refused
unless explicitly opted in.

| Env | Effect |
|-----|--------|
| `INSIKA_EGRESS_HOSTS` | host allowlist (CSV) — the safe, specific way to permit a backend |
| `INSIKA_EGRESS_ALLOW_HTTP=1` | permit plain `http` — **loopback dev only** |
| `INSIKA_EGRESS_ALLOW_PRIVATE=1` | permit private/loopback IPs — **dev only** |

Restricting `INSIKA_EGRESS_HOSTS` to exactly the hosts a tool needs is
defense-in-depth: without it, `ALLOW_PRIVATE` opens *any* private destination.
**Never set the `ALLOW_*` vars in a cloud deployment** — a public backend over
`https` already passes the strict default.

> ⚠️ A blocked egress **fails silently** — the tool returns an error to the model,
> the request never leaves the process, and the conversation *looks* fine. Verify
> tool health by the Studio session **trace** (a healthy call shows the backend's
> `200`), never by the model's reply. Full detail in
> [Tools §Egress](TOOLS.md#egress-the-ssrf-guard-and-its-silent-failure).

## Sandbox: confined execution

Code tools that touch the filesystem or run commands do so through a **sandbox** —
a single, pluggable primitive chosen by config, following the principle of the
*narrowest sandbox that supports the task*:

- **Filesystem confinement is always on, host-side.** Every path is proven to
  live inside one root *before any IO happens* — `..` escapes, absolute paths
  outside the root, and symlinks pointing out are all refused. An escape returns a
  structured error, never a crashed turn.
- **Command execution is via a swappable provider.** `local` (in-process, the
  default — cheap, but *not* an isolation boundary for a shell) or `docker` (a
  throwaway container with `--network none`, memory/cpu caps, and a minimal image).
  Untrusted execution should use `docker`.

Both providers enforce a hard-kill wall-clock timeout that also reaps child
processes. The provider is **data on the agent profile** (a `sandbox` block), not
a branch in tool code. Full detail — including the config shape — in
[Sandbox](SANDBOX.md).

## Secrets live only in the environment

Secrets never live on disk in agent or tool definitions, and are never exposed to
the model:

- A data tool references a secret with `{{secret.*}}`, allowed **only** inside a
  header named in `secret_headers`; the real value is injected at provision time
  and stored masked. A stray `{{secret.*}}` anywhere else is rejected. See
  [Tools](TOOLS.md#data-tools-a-tool-is-a-row).
- Full tool results are stored **masked** in the trace store; the copy persisted
  into the transcript is capped.
- Provider keys and the API bearer token come from the environment (see
  [Deploy](DEPLOY.md)). Rotating the API bearer requires updating both the runtime
  and every consumer in the same step.

## Grading sends text to a judge (evals)

A rubric is scored by a model, so running an eval sends that case's **user turns and
the assistant reply** to every judge in the panel ([Evals](EVALS.md)). Two
consequences worth stating out loud:

- **The judges are a second provider surface.** Configure them deliberately: a panel
  of three models is three vendors seeing those conversations. Judges are opt-in and
  empty by default — with none configured, only the deterministic assertions run and
  nothing leaves the deployment.
- **A case is curated text, not live traffic.** The corpus is authored from real
  conversations with PII removed at curation time. That masking is a human step, not
  an automatic one: treat a golden case as something that WILL be read by an external
  model and reviewed in a pull request.

## Reading traffic back (refinement)

A refinement run reads an agent's own transcripts and tool traces to report what
broke ([Refinement](REFINEMENT.md)). Two properties keep that from becoming a
second copy of your customers' data:

- **It quotes as little as possible, redacted.** Only the `repetition` finding
  carries customer words, and every snippet goes through the same detectors that
  redact a customer-facing turn (formatted CPF/CNPJ, API secrets). Tool arguments
  and results are never copied — only the normalized error signature is. That is
  not a general PII scrubber: a phone number typed into a chat can survive into a
  snippet, so the page sits behind the Studio login like the transcripts do.
- **Provenance is ids.** A run record stores session ids, never their contents, and
  the events it emits carry counts only.

### Editing an agent from its traffic

A run can also propose a change to the agent's instructions, and that path is opt-in
per agent (`refinement.mode`), off by default, and bounded by construction rather
than by instruction:

| Surface | Reachable? | Why |
|---|---|---|
| the files listed in `refinement.files` | **yes** | text you already edit by hand, versioned, one-click restore |
| skill bodies and descriptions | **yes** | same trust level, same history |
| guardrails, the safety corpus | **no** | a constrained thing does not edit its own constraints |
| tool definitions and schemas | **no** | tools are authored by a person; a wrong schema is theirs to fix |
| policies, approvals, denied tools | **no** | authorization is not a prompt concern |
| model pins, limits, edge config | **no** | cost and latency are the operator's decisions |
| the system preamble the engine assembles | **no** | the fixed frame of a turn |

There is no code path to the "no" rows — not a rule in a prompt. Three more
properties are worth stating because each one is a way this could have gone wrong:

- **An edit is verified by running it, not by asking a model.** The candidate is
  applied to a throwaway clone of the agent and the golden set is replayed against
  it; any regression disqualifies it. An agent with no cases, with no recorded
  baseline, or with a baseline in which nothing passes, **cannot be edited at all** —
  the gate refuses instead of passing vacuously. That last case is the subtle one: a
  regression is measured against a case that was passing, so an all-red baseline
  cannot produce one and would wave everything through.
- **A human approves.** A gate pass parks the proposal for review; nothing applies
  itself. Approving writes through the versioned file store, so undo is the Restore
  button that was already there.
- **Prompt injection buys nothing.** Evidence reaches a proposer as quoted, masked
  data, and whatever comes back is validated against the candidate schema and the
  file allowlist. The worst an injected instruction can achieve is a proposal that
  gets dropped or fails the gate.

## Config discipline

Configuration is validated against a schema of known keys at boot. An unknown key
in the `INSIKA_` namespace (a typo the runtime would otherwise ignore) or a
wrong-typed value is **surfaced**, and `INSIKA_CONFIG_STRICT=1` turns findings
into a boot refusal. By default the engine warns and boots on last-known-good — a
rotated key or a typo never takes the whole service down. The `insika doctor`
command runs the same checks on demand against a live database. See
[Deploy](DEPLOY.md#strict-config-and-insika-doctor).

## See also

- [Agents](AGENTS.md) — the five access layers per agent.
- [Tools](TOOLS.md) — egress and secret placeholders in depth.
- [Sandbox](SANDBOX.md) — the confinement primitive.
- [Deploy](DEPLOY.md) — tokens, rotation, and strict config.
