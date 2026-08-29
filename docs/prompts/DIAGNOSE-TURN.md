---
title: Prompt — diagnose a failed turn
parent: Reference
nav_order: 4
permalink: /diagnose-turn/
layout: default
render_with_liquid: false
---

# Diagnose a turn that failed or misbehaved

> **You are a coding agent** (Claude Code, Codex, Cursor, …) reading this because a
> developer pasted a prompt pointing here — something like *"the agent didn't answer /
> answered wrong / errored"*. Treat this file as a **skill**: investigate BEFORE
> proposing fixes, and report findings in plain language with evidence.

The engine already recorded what happened: every turn emits structured events stamped
with `task_id`/`session_id`. Your job is to read the record, not to guess.

## Step 0 — Pin down the facts

Ask for (or find) the minimum: **agent id**, **session id** (or the customer's message
text), roughly **when**, and expected vs. actual. Reproduce once locally if cheap
(`reply()` or one `curl` against a dev instance) — never hammer production.

## Step 1 — Read the record, in this order

1. **`GET /v1/tasks/:id`** (or the Studio) — the terminal state:
   `completed` / `failed` / `cancelled`, outcome, usage, timing. No task id? Find it
   via **`GET /v1/events?session_id=…`**.
2. **That task's events**: `task_started` → `tool_call`/`tool_result`/`data_tool_call`
   … → the terminal event. A failure's reason lives there.
3. **`GET /v1/sessions/:id`** — the transcript: what the model actually saw and said.
4. **`bin/insika doctor`** — configuration sanity; relay its findings verbatim.

## Step 2 — Map symptom to mechanism

| On the record | Usual suspect | Details |
|---|---|---|
| provider auth/model error | missing key or wrong model id | fails at the provider, not the engine |
| `provider_failure` then `provider_fallback` | reliability chain rotated mid-turn | [Agents](../AGENTS.md) § reliability |
| `breaker_open` + fail-fast turns | circuit open until cooldown | same |
| turn completed, customer got nothing | delivery is separate from the turn: check `channel_delivered` / `delivery_failed` | [Channels](../CHANNELS.md) |
| freshly created agent returns empty turns | persona overflows the default `context_budget` (8000) | [Context](../CONTEXT.md) |
| tool never called (or "missing") | not registered OR not allowed (`tools_allow`) | [Tools](../TOOLS.md) § troubleshooting |
| identical `tool_call` repeated, then abort | the `max_tool_repeat` loop guard | [Agents](../AGENTS.md) § limits |
| model gave up after one empty result | `tool_persistence` off (it is ON by default) | same |
| `turn_stuck` event | the agent declared it cannot proceed — escalation signal, not a bug | [Agents](../AGENTS.md) § stuck |

## Step 3 — Report, then fix ONE thing

- Plain-language summary: **what happened → evidence (event names + ids) → root cause
  → the fix you propose.**
- Apply the fix; re-run the Step 0 reproduction; show the new terminal event as proof.
- If the evidence does not fit any row above, say so and bring the raw events back —
  do not force a diagnosis.

## Hard constraints

- **Never invent event data.** If you did not read it, you cannot claim it.
- **Do not change config just to silence the symptom** without explaining the
  mechanism (raising `context_budget` because the prompt is big is a fix; deleting the
  guardrail that fired is not).
- **Quote ids, counts and states first; message content only when needed** for the
  developer to recognize the case.
