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

### Multi-tenant mode (`INSIKA_TENANCY=multi_tenant`)

A single operator-grade token cannot host N stores. With `INSIKA_TENANCY=multi_tenant`
the Bearer is resolved to a **principal** before the routes:

- **Per-tenant tokens** (`POST /v1/commands/issue_tenant_token`) scope a caller to
  one tenant; **operator** tokens (and the legacy gateway token — an existing
  deployment switching modes keeps its credential) have the run of the deployment.
- Tokens are stored **only as SHA-256 hashes**; the plaintext is shown exactly once,
  at issue time. Rotation (`rotate_tenant_token`) and revocation (`revoke_token`)
  are operator commands — revoking one tenant's token never touches another's.
- A tenant principal reaches only its **own runtime surfaces** (`/v1/sessions`,
  `/v1/messages`, `/v1/responses`, workflow runs, and its own session/task/event
  reads). Every authoring/provisioning/config surface answers `403` to a tenant.
- Isolation is the key, not a convention: a tenant's sessions live under
  `<tenant>:<session-id>`, its commands carry `meta.tenant` (memory scoping,
  event tagging), and reading another tenant's session/task reads as `404`.

`single_tenant` (the default) is exactly the classic behavior above — one
operator credential, no principal, no stamping.

## The `/v1` contract is versioned by date

Every `/v1` route reads an optional `Insika-Version: YYYY-MM-DD` header, checked
before the Bearer gate above. Absent header means today's (only) behaviour; an
unknown value is a `400`, not a silent fallback — a caller that pins a version
finds out immediately that it does not exist, rather than being served whatever
happens to be current. `/a2a` and `/channels/<id>/…` are versioned by their own
contracts (JSON-RPC, the platform's own shape) and never read this header.

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
  on top. The moderator is **fail-open**: an error or an unparseable reply never
  blocks a legitimate customer — but silence is not a negative. That third state
  surfaces as a `:guardrail_flagged` event with category `moderator_unavailable`,
  so a degraded tier is distinguishable from a healthy one in the audit stream.
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
- **The proposer reads the allowlisted files and nothing else.** Those it gets
  verbatim and unmasked, which sends a model nothing it was not already sent on every
  turn — they are the agent's own instructions. Masking them would break anchoring
  (a `before` copied from a masked view never matches the real file) and protect
  nothing. Files outside the allowlist are not shown at all.

**Know what the gate does not measure.** It catches an edit that breaks a case you
wrote; it cannot catch one that breaks something no case covers. Two of its blind
spots are this engine working correctly rather than gaps — an edit cannot remove a
tool (availability is `tools_allow`, not prose) and it cannot make a reply leak PII
(the output guardrail redacts first) — but the general point stands, and it is
[stated plainly in Refinement](REFINEMENT.md#what-the-gate-can-and-cannot-catch).
The structural limits above hold regardless; the gate is the layer that has to be
earned with cases.

## Config discipline

Configuration is validated against a schema of known keys at boot. An unknown key
in the `INSIKA_` namespace (a typo the runtime would otherwise ignore) or a
wrong-typed value is **surfaced**, and `INSIKA_CONFIG_STRICT=1` turns findings
into a boot refusal. By default the engine warns and boots on last-known-good — a
rotated key or a typo never takes the whole service down. The `insika doctor`
command runs the same checks on demand against a live database. See
[Deploy](DEPLOY.md#strict-config-and-insika-doctor).

## Memory and the right to be forgotten (LGPD, RFC-0031)

Memory is scoped per **`(tenant, customer)`** — the cell `"memory:<tenant>:<customer>"`
is the isolation boundary. A query against one tenant never touches another's
cells. A turn with no customer falls back to the session's own **marked** cell
(`"memory:chat:<session id>"`) — the marker keeps the Studio drill and the doctor
from ever reading a conversation as a customer (a bare `memory:<id>` cell is
indistinguishable from a single-tenant customer ref). Cells written before the
marker (bare session ids) may still appear as customers in the drill until
forgotten or aged out. Three operations enforce the right to be forgotten:

- **Retention** — the `memory_ttl_days` setting (platform default per cell, or an
  ops-authored per-tenant map) sweeps facts older than the window. A per-fact
  `expires_at` override wins over the cell TTL. Both run on the daily retention
  tick, **not** gated by `retention_days` (the conversation-footprint window).
  Note the interaction: an explicit `expires_at` also exempts the fact from the
  `retention_days` age-based sweep — an explicit date owns that fact's life, so a
  far-future date makes the fact immune to *both* age passes. Export and forget
  still see it; the only way to remove it early is the Customers drill.
- **Export** — `export_customer_memory` returns the full fact + note content to the
  **operator** (the Studio turns it into a JSON download). The emitted event carries
  counts only — the event stream, the audit store and every log stay content-free.
- **Forget** — `forget_customer` purges the customer's memory cell AND their
  sessions (and everything those sessions left behind: traces, tasks, checkpoints,
  outbox deliveries). The operator-mutation audit store records a digest-free line
  ("a purge happened, with N records") — content-free by construction.

### Distilled facts are personal data (RFC-0034)

The distillation loop ([Facts](FACTS.md)) writes **proposals** — a distilled
fact's name and value are personal data, and they are treated like the rest of
the memory footprint: `forget_customer` deletes the person's proposals (every
status), `delete_tenant_data` deletes a tenant's, and the `retention_days`
sweep ages them out with the transcripts they were distilled from. Provenance
holds: an approved fact is written with `origin: "distilled:<session_ref>"`
(the RFC-0031 closed set gains one spelling, never an open string). Events and
audit carry ids and counts only — a fact value never enters the stream, the
ledger or a log; the evidence excerpt is a link read from the transcript at
request time, never a copy.

The doctor's `memory-scopes` check flags bare cells only in a `multi_tenant`
deployment (in `single_tenant` the bare cell is the designed customer shape), and
never the session-marked cells. See [Context](CONTEXT.md#memory) and
[Deploy](DEPLOY.md#strict-config-and-insika-doctor).

### Harvest candidates are derived data (RFC-0035)

The harvest loop ([Harvest](HARVEST.md)) writes **candidates** — a mined skill
proposal is behavior instructions, the same trust level as any skill content,
and it is store-scoped, never customer-scoped: `forget_customer` does NOT reach
it (a candidate's skill body is not customer content). Candidates reference
sessions by id and their evidence excerpt is the transcript rendered at request
time through the output filter — never a copy. `delete_tenant_data` purges a
tenant's candidates, promotion rows and markers; the `retention_days` sweep
ages them out with the transcripts they were derived from (they are
re-derivable — pruning is never data loss). **No auto-application**: nothing
reaches the catalog without a human click, and the grounding filter refuses any
product claim the origin sessions' evidence ledger did not see. Events and the
promotion log carry ids, refs and verdicts only — a skill body never enters
the stream.

### Learned knowledge is redacted before it is stored

The [Knowledge](KNOWLEDGE.md) loop writes **concepts** extracted from finished
conversations — store-scoped, not customer-scoped, but written from real
transcript text, so the write path is deliberately conservative: a concept's
body goes through the same PII/secret redactor the output guardrail uses
before it is ever persisted, and `sources` holds session ids only — never
message content, never a customer identifier. This is the one write path in
the engine where a model-authored field is rejected outright rather than
merely validated: `provenance`, `confidence`, `sources` and the timestamps are
stamped by the engine, so a model cannot self-assign trust it did not earn or
smuggle a scope into a store-wide record. A repeat sighting that contradicts
what's on record is never silently merged — the conservative default when
the engine cannot tell is to flag it for a human, not to guess. Events carry
names and counts only — a concept's content never enters the stream.

## See also

- [Agents](AGENTS.md) — the five access layers per agent.
- [Tools](TOOLS.md) — egress and secret placeholders in depth.
- [Sandbox](SANDBOX.md) — the confinement primitive.
- [Deploy](DEPLOY.md) — tokens, rotation, and strict config.
