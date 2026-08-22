# agent-tester

Simulate a customer against your own agent. A persona model — the
cheap platform `utility_model` — plays a customer whose **only** facts are the
persona's `knows`, and the target agent answers until the persona's `max_turns` or a
stop marker (`<<goal_met>>` / `<<gave_up>>`).

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/agent_tester.rb
```

Prints the generated transcript and the judge's verdict on the whole conversation
(not just the last turn).

## What the file demonstrates

- **The persona is the whole instruction.** `persona.yml` (in the script) has a goal,
  a style, an opening message, the `knows` facts and `max_turns`. The customer model
  is told it may assert ONLY those facts — anything else is answered with ignorance.
  See [`docs/EVALS.md`](../../docs/EVALS.md) "Simulated users".
- **The transport is in-process.** `GraphTransport` drives the local graph the way a
  customer would reach it (tools and guardrails included), no server in between. The
  same Simulator rides `HttpTransport` against a remote deployment, or a thin A2A
  transport against an agent that only speaks A2A.
- **The safety gate is derived, not hand-maintained.** The engine marks `side_effect`
  on tools (a data-tool's non-GET method, the MCP ingestor's `tools/call`). The run
  computes the agent's reachable side-effect tools from the registry and refuses to
  run if any can write — unless you declare the target staging or use an eval profile
  where they are swapped for dry-runs. Every run is `simulated: true`, so a report
  never mixes a generated conversation with real traffic.- **The judge reads the whole conversation.** The rubric is scored against every user
  and assistant turn interleaved — a rubric about the exchange ("does it discover the
  objective before recommending?") is unanswerable from the last reply alone.

## As a tool a QA agent calls itself — `qa_scheduled.rb`

`agent_tester.rb` above is a one-off script. `qa_scheduled.rb` wires the SAME
Simulator + Judge as a tool (`run_persona_eval`, C3.1) a scheduled QA agent
calls on its own — the Scheduler + Artifacts + Simulator
in one flow:

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/qa_scheduled.rb
DEEPSEEK_API_KEY=sk-... ruby examples/agent-tester/qa_scheduled.rb --serve
```

A `qa` agent, allowlisted for `run_persona_eval` + `save_artifact`, runs the
seeded persona case against its sibling `assistant` agent and publishes the
verdict as an artifact — weekly, on its own schedule, or once now. See
[`docs/EVALS.md`](../../docs/EVALS.md) "`run_persona_eval` — a QA agent that
tests other agents" for what it refuses (any target with a reachable
side-effect tool — no swap is wired for an in-process run yet) and how its
own spend is charged (to the QA agent's turn, never the target's).

## To run against a remote deployment instead

```bash
insika evals:simulate --persona examples/agent-tester/persona.yml \
  --target https://your-deployment.example.com --staging
```

`--staging` (the target is a staging deployment) or `--eval-profile` (side-effect
tools are swapped) is required: a simulated run must not write for real.
`--eval-profile` is verified against the target's derived side-effect tools — the CLI
derives them (the deployment's own registry over `GET /v1/agents/:id`, or the local
store when `INSIKA_DB` is set) and refuses unless `--eval-tools <a,b,c>` names every
one; an A2A target requires the explicit list.
