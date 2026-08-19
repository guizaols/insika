---
title: Schedules
parent: Operate & prove it
nav_order: 8
permalink: /schedules/
---

# Schedules — recurring turns the engine fires

A schedule is a turn nobody has to remember to send: a daily report at 22:00,
an eval sweep every night, a heartbeat every hour. The engine fires it on its
own periodic tick — no cron on some other box pointing at an authenticated
route. (That route still works, if you want it; the built-in trigger just
removes the homework.)

A schedule is **declared on the agent** — pack data, like `followup:` or the
budget — in one of the same three places every profile field is edited: the
DSL at import, `POST /v1/agents` in the pack, or the Studio's config form
(the **Schedules** group on the agent page). Edits are hot: the next pass
sees them.

## The declaration

```ruby
agent = Insika.agent("reporter") do
  schedule "daily_report", cron: "0 22 * * *", tz: "America/Sao_Paulo",
           message: "Run the daily report now.",
           overrides: { turn_timeout: 900, max_tool_calls: 200 }
  schedule "heartbeat", every: 3600, message: "Say you are alive."
end
```

| Key | Meaning |
|---|---|
| `id` | the schedule's name (the argument). Lowercase, `[a-z][a-z0-9_-]*` |
| `cron` | a five-field expression (`minute hour day-of-month month day-of-week`), or |
| `every` | a plain interval in seconds — the two are **exclusive** |
| `tz` | IANA zone for **cron** materialization (default `Etc/UTC`). `every` never needs it — every comparison runs in UTC |
| `message` | the synthetic inbound that kicks each run — what the agent "hears" |
| `session_mode` | `"new"` (default) — a fresh session per run, the report shape; `"fixed"` — one standing session, the "standing assistant" shape |
| `session_id` | for `fixed` sessions: the standing session (created on first run when missing) |
| `overrides` | per-run ceilings: `turn_timeout`, `max_tool_calls`, `model` — a report needs a bigger ceiling than a chat turn; the base profile is untouched |
| `enabled` | `false` pauses the schedule (the Studio toggle / the JSON field) |

> **The cadence floor.** Firing rides one claim window per pass — a schedule
> fires **at most once per window**. That is the true cadence ceiling: an
> `every: 60` does not fire sixty times a minute, it fires once per window.
> `doctor` warns when a declared `every` is shorter than the claim window.

The Studio renders the schedules section as a JSON array of the same
declarations plus a read-only card: each schedule's next fire, last run and —
when a window was skipped — the skip reason. `doctor` parses every
declaration with the engine's own parser: an invalid cron, an unknown
runtime zone, a schedule with neither trigger, an unknown override key —
each is named, per agent, as an error finding.

## The engine's triggers: cron subset

Five fields, whitespace-separated. Per field: `*` (or `?`), a single value, a
range (`N-M`), a step (`*/N`, `N-M/N`, `N/N`), or a comma list of those.
Day-of-week is `0-7` with `7` = Sunday; when **both** day fields are
restricted the date matches on **either** (standard cron OR semantics).
`L`, `W`, `#` and month/day names are refused loudly at creation — the engine
will not silently ignore a cron that only some dates understand.

```text
 minute  hour  day-of-month  month  day-of-week
   0      22        *          *         *
```

## Firing: one turn per window, no catch-up

Firing rides the tick, gated by its own claim window (one scheduler per
window across `N` workers — the same claim the outbox and recovery sweeps
use). Each due schedule is claimed transactionally: the task and the
schedule's state (last run, last task id, next fire) commit together, so two
workers racing serialize on the backend's lock and **exactly one fires per
window**.

Three skip rules are part of the contract, all recorded on the schedule and
shown in the Studio — never silent, never queued:

- **late** — the no-catch-up policy. A window more than one claim window in
  the past is **missed, not replayed**: a deploy that was down over 22:00 does
  not fire a 22:00 report at 06:00 the next morning. The schedule's lattice
  advances to the next window and the skip is recorded.
- **overlap** — the previous run's task is still live (`queued`/`running`/
  `waiting`/`paused`). The window is skipped, recorded, and the next one
  fires. There is no queue buildup: one scheduled run at a time per schedule.
- **budget** — a **hard** calendar budget (`budget daily: …` on the profile)
  already at/over its cap. The edge would fail the turn anyway; the engine
  refuses to even queue it. A `soft` budget crosses and runs — the ledger
  warns as usual.

A bounded run also costs what it costs: the run's usage lands on the same
`BudgetLedger` the edge enforces, and `billed = total + cached +
cache_creation` — a long report is cache-heavy, measure the caps against it.

## What a schedule run is

A first-class turn, stamped `origin: "scheduled"` so a refinement read can
never mistake the engine's kick for a customer speaking. It enters through the
pipeline directly (never through the message edge, so no rate-limit/token
ceiling gate applies — same as a resume), is charged to the ledger like any
turn, and its result is delivered wherever the agent's outputs go: a channel
answer, or – for the report shape – nothing at all, when the run publishes an
artifact instead. The Studio's schedule card links the last run's task.

No customer ever receives anything from a schedule unless your agent sends a
message in reply — the engine contacts no one.

## The boundaries

- **Not a job queue.** No priorities, no fan-out, no retries of a failed run
  beyond what Recovery already does for any task.
- **Not the follow-up feature.** `schedule_followup` is a one-shot,
  customer-facing, consent-gated contact from inside a conversation — and it
  keeps being that. These schedules are operator-declared recurring internal
  triggers: no contact policy, no consent, no customer.
- **Not a replacement for your cron.** The external route stays; this is the
  built-in one.