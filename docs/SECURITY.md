# Security

An agent runtime runs untrusted input through a model that can call tools and
touch the outside world. Insika treats that as the core problem, not an add-on.
Every control below is **built into the engine**, **configured as data** (not
hand-rolled per agent), and composes with the others. This page is the map;
each section links to the deeper guide.

The layers, from the edge inward:

1. **[Edge limits](#edge-limits)** — stop a flood before it costs anything.
2. **[Input guardrails](#guardrails)** — refuse injection/abuse without a model turn.
3. **[Human approval](#human-approval)** — gate high-risk tool calls on an operator.
4. **[Egress guard](#egress-the-ssrf-boundary)** — bound where a tool can reach.
5. **[Sandbox](#sandbox-confined-execution)** — bound where code can run.
6. **[Output guardrails](#guardrails)** — moderate and redact what streams back.
7. **[Secrets](#secrets-live-only-in-the-environment)** — never on disk, never in the model.

## Edge limits

The outermost gate. The edge limiter wraps a turn **before** the input guardrail,
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
moderator off. See [`examples/guardrails/`](../examples/guardrails/).

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
