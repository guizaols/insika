---
title: Prompt — run every example
parent: Reference
nav_order: 2
permalink: /run-examples/
layout: default
render_with_liquid: false
---

# Run every example

> **You are a coding agent** (Claude Code, Codex, Cursor, …) reading this because a
> developer pasted a prompt pointing here. Treat this file as a **skill**: follow the
> steps in order and apply the RULES literally. Do not improvise beyond them.

Your job: get every runnable example under `examples/` running — one at a time — and
explain to the developer what each one demonstrates. The authoritative list (and the
one-line capability per example) is
[`examples/README.md`](https://github.com/guizaols/insika/tree/main/examples/README.md)
(`examples/README.md` when the repo is checked out). Read it first.

## Step 0 — Gather context (do this first, silently)

RULES — verify, do not assume:

- **Ruby ≥ 3.3.** Run `ruby -v`. If lower, stop and tell the developer; do not try to
  upgrade Ruby for them.
- **Insika must be loadable** — `require "insika"` (installed gem) or the checked-out
  repo's bundle. Do not copy source files around to "fix" a missing install.
- **A provider key comes from the environment** (`DEEPSEEK_API_KEY` for the demo).
  None is set → **ask the developer**; never invent or hard-code one.
- **Read each example's own `README.md` before running it.** Some need more than one
  terminal or extra env vars; the README is the contract.

## Step 1 — Run in this order, ONE at a time

| # | Example | Command | Note |
|---|---------|---------|------|
| 1 | hello-agent | `ruby examples/hello-agent/hello.rb` | smallest agent; one turn |
| 2 | data-tool | `ruby examples/data-tool/currency_agent.rb` | declarative HTTP tool + the egress guard |
| 3 | skills | `ruby examples/skills/skill_agent.rb` | progressive skill loading |
| 4 | memory | `ruby examples/memory/memory_agent.rb` | cross-session `remember` |
| 5 | guardrails | `ruby examples/guardrails/guarded_agent.rb` | content-safety guardrails |
| 6 | agentic-workflows | `ruby examples/agentic-workflows/sequential.rb` | then routing/parallel/delegation/evaluator |
| 7 | scheduled-report | `ruby examples/scheduled-report/report_agent.rb` | runs one report turn inline; add `--serve` only if asked |
| 8 | relay-channel | see its README | TWO processes + env vars; skip unless asked |

For each one: read its README → run → quote what it printed → explain in ≤ 3 lines
what capability it demonstrated.

Skip unless the developer asks: `insika-code/` (a full deployment, not a one-file
script), `quickstart.rb` (hello-agent already covers it), and anything in `examples/`
the table above does not list.

## Step 2 — When one fails

- **Auth or model error** → stop that example, report the exact error, ask for a valid
  key/model id. Never retry with a guessed id.
- **A cause you can read from the output** (missing env var, port already bound…) →
  say so and fix only with the developer's OK.
- **Never edit an example to make it pass silently.** An example that needed a change
  to run is a finding, not noise.

## Step 3 — Self-check before you report done

- [ ] Every example above either printed real model output or was reported blocked,
      with the exact blocker.
- [ ] No provider key written into any file; no invented model ids.
- [ ] Each example got its ≤ 3-line "what this demonstrates".
- [ ] Nothing was edited to make a failure disappear.
