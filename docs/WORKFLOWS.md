---
title: Workflows
parent: Core concepts
nav_order: 6
permalink: /workflows/
---

# Workflows

A single agent's tool-loop is one shape of work: the model decides, calls a tool,
looks at the result, decides again. Plenty of real work has a shape you already
know — draft then edit, classify then answer, three reviewers then a summary,
try until it passes. For those, the choice of "what happens next" belongs in
**Ruby**, not in a prompt.

That is a **workflow**: deterministic orchestration around agent turns.

## The one decision that matters

**Who chooses the next step — your code, or the model?**

| | **Workflow** | **Delegation (`subagents`)** |
|---|---|---|
| Chooses the next step | your Ruby | the model |
| Cost of deciding | zero | a model call |
| Repeatable | yes — same path every run | no |
| Reach for it when | the shape is known in advance | the work depends on what the user said |
| Surface | `workflow` in a system + `POST /v1/workflows/:name` | `subagents` on a profile + `spawn_subagent(s)` |

They compose: a workflow step can `ask` an agent that itself delegates. Start
with a workflow and hand the choice to the model only where the choice is
genuinely open — see [Agents](AGENTS.md#delegation-subagents) for delegation.

## Declaring one

Workflows live in a **system** (`Insika.system`), because their steps address
agents by id and those agents must resolve in the same runtime:

```ruby
newsroom = Insika.system do
  provider :deepseek

  agent("writer") { model "deepseek-v4-flash"; instructions "Write ONE paragraph." }
  agent("editor") { model "deepseek-v4-flash"; instructions "Rewrite as ONE sentence." }

  workflow "publish",
           description: "Draft a paragraph, then tighten it.",
           input:  { type: "object", properties: { topic: { type: "string" } }, required: ["topic"] },
           output: { type: "object", properties: { headline: { type: "string" } } } do |input, ctx|
    draft = ctx.ask("writer", "Topic: #{input['topic']}")
    { "headline" => ctx.ask("editor", draft) }
  end
end

newsroom.run("publish", input: { "topic" => "Ruby fibers" })
# => { "headline" => "…" }
```

What the block receives:

| | What it does |
|---|---|
| `input` | the validated input Hash (string keys) |
| `ctx.ask(agent, message)` | one turn against one agent of the system → its text |
| `ctx.gather(*blocks, max: 8)` | runs blocks **concurrently**, returns values **in order** |
| `ctx.context` / `ctx.tools` | the turn's ContextPackage and its resolved tool instances — escape hatches, rarely needed |

The workflow's return value **is** its output: whatever Hash (or value) you
return is what `run` returns, what `:workflow_completed` carries, and what the
`output` schema validates.

## What you get for free

- **A durable run.** The run id *is* a Task — checkpointed and recoverable, so a
  crash mid-run does not lose the record. `run_id` comes back from every trigger.
- **Schemas at the edges.** `input:` is validated **synchronously**: a bad input
  is refused with **no run created** (a `422` over HTTP). `output:` is validated
  when the workflow returns; a violation fails the run at the `workflow_schema`
  stage instead of handing a malformed result downstream. Both take a JSON Schema
  Hash or any dry-schema-compatible validator.
- **Events.** `:workflow_started` and `:workflow_completed` (with the typed
  output) on the turn's event stream, alongside every step's own turn events.
- **Every step is visible.** Each `ctx.ask` is its own turn — its own Task, its
  own trace in the Studio. A workflow is not a black box.

## Over HTTP

Workflows are exposed when the deployment injects the registry (a `serve`d system
with at least one workflow does it automatically):

```bash
GET  /v1/workflows                      # discovery: names, descriptions, I/O schemas
POST /v1/workflows/publish              # 202 { run_id, task_id } — fire and observe
POST /v1/workflows/publish?stream=true  # SSE of the run, ending at workflow_completed
```

```jsonc
// POST body
{ "agent": "writer",                    // the profile the run executes under
  "input": { "topic": "Ruby fibers" },
  "session_id": null }                  // optional
```

Observe an async run with `GET /v1/tasks/:run_id` or
`GET /v1/events?task_id=:run_id`. A bad input is a `422`; an unknown workflow or
agent is a `404`.

## The five patterns

Each has a runnable script in
[`examples/agentic-workflows/`](https://github.com/guizaols/insika/tree/main/examples/agentic-workflows/).

### Sequential (prompt chaining)

Each step's output feeds the next. The order is code, so it is identical on
every run.

```ruby
draft = ctx.ask("writer", input["topic"])
ctx.ask("editor", draft)
```

### Routing

One cheap classification turn, then a specialist with a short, focused prompt —
instead of one agent carrying every instruction it might ever need.

```ruby
label = ctx.ask("router", input["message"]).downcase       # constrain the label set
lane  = label.include?("billing") ? "billing" : "technical"
ctx.ask(lane, input["message"])
```

**Do the branching in Ruby, with a fallback.** A closed label set plus an `else`
means an unexpected answer degrades instead of picking a random branch.

### Parallel (fan-out / fan-in)

An LLM turn is almost all *waiting* on the provider, so independent turns overlap
on the fiber scheduler: wall-clock is the **slowest** branch, not the sum.

```ruby
security, performance = ctx.gather(-> { ctx.ask("security", code) },
                                  -> { ctx.ask("performance", code) })
ctx.ask("lead", "security: #{security}\nperformance: #{performance}")   # fan-in
```

`gather` returns values in declaration order and caps concurrency at `max:`
(default 8) — the cap matters, because N simultaneous calls hit provider rate
limits and per-agent token ceilings.

### Evaluator-optimizer

Produce, judge, revise. The judge's reason becomes the revision instruction.

```ruby
loop do
  verdict = ctx.ask("critic", "Brief: #{brief}\nTagline: #{tagline}")
  break if verdict.include?("PASS") || attempts >= MAX_ATTEMPTS   # the cap is CODE
  tagline = ctx.ask("writer", "Fix this: #{verdict}")
  attempts += 1
end
```

**Two things must be code, not prompt:** the attempt cap (a loop that asks the
model when to stop can run forever) and the honest report of whether it actually
passed. Have the judge answer in a shape you can branch on (`VERDICT: PASS|FAIL`).

### Orchestrator-workers

The model chooses the workers. This is delegation, not a workflow — see
[Agents](AGENTS.md#delegation-subagents).

```ruby
agent "lead" do
  instructions "You have no expertise yourself — always delegate, then report."
  subagents "security", "performance"
end
```

## Gotchas

- **`ctx.ask` is stateless.** A step is a unit of work, not a conversation: no
  session is threaded, so the agent sees only the message you pass. Pass what it
  needs.
- **Nothing forces the model to delegate.** If a parent answers alone, the task
  list shows only the parent — and it is the *prompt* that needs work: say
  plainly that it has no expertise of its own. (The engine helps by naming the
  spawnable agent ids in the tool contract, but it cannot make the model use them.)
- **The `agent:` of a run is the profile it executes under** — its policy,
  limits, and guardrails. It is not "the agent that does the work"; the steps
  pick those themselves.
- **A workflow turn assembles no chat.** Stage 5 is skipped: there is no
  model call for the *workflow itself*, only for the turns its steps start.
  One consequence worth naming: `queue_mode: "steer"`
  ([Agents](AGENTS.md#steer--the-message-arrives-while-the-turn-is-already-running))
  cannot append into a running workflow — there is no chat to append to, and no tool
  batch of the engine's to use as a boundary. A message that arrives while a workflow
  run is in flight becomes the next turn on the session, which is what `followup`
  does. Steering is refused at the door, not silently dropped.
- **A running workflow reaches no boundary until it returns.** The engine's stage
  boundaries sit *around* the workflow call, not inside it, so `queue_mode:
  "interrupt"` (and a plain `cancel_task`) is observed only once the workflow is done:
  the steps run, and then the run is abandoned without publishing or persisting. If you
  need a run to stop early, that decision belongs inside the workflow — it is ordinary
  Ruby, so `return` on the condition you care about.
- **Braces bite in Ruby.** `agent "x" { … }` is a syntax error (`{` binds to the
  argument); write `agent("x") { … }` or `agent "x" do … end`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `GET /v1/workflows` 404s | no workflow declared, so the routes are not exposed (parity) |
| `422` on trigger | the input violates `input:` — the message names the offending field |
| `404` on trigger | unknown workflow name, or the `agent:` does not exist |
| run fails at `workflow_schema` | your return value violates `output:` |
| a step "does nothing" | the agent id is not in this system — `ask` raises with the list of valid ids |

## See also

- [Agents](AGENTS.md) — profiles, and delegation via `subagents`.
- [Tools](TOOLS.md) — what a single agent can call inside one turn.
- [Architecture](ARCHITECTURE.md) — the turn pipeline a run goes through, and checkpointing.
- [`examples/agentic-workflows/`](https://github.com/guizaols/insika/tree/main/examples/agentic-workflows/) — the five patterns, runnable.
