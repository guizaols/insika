# Agentic workflow patterns

The five composition patterns, one runnable script each, all on the public DSL.
Each script prints what it did so you can see the shape, not just the answer.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/agentic-workflows/<file>.rb
```

| Pattern | What it is | Insika primitive | File |
|---------|-----------|------------------|------|
| **Sequential** | each step's output feeds the next | a `workflow` calling `ctx.ask` in order | [sequential.rb](sequential.rb) |
| **Routing** | classify first, then send to a specialist | a `workflow` branching on a router's answer | [routing.rb](routing.rb) |
| **Parallel (fan-out/fan-in)** | independent work at once, then synthesize | `ctx.gather` in a workflow, or `spawn_subagents` from an agent | [parallel.rb](parallel.rb) · [delegation.rb](delegation.rb) |
| **Evaluator-optimizer** | produce, judge, retry until it passes | a `workflow` with a Ruby loop | [evaluator.rb](evaluator.rb) |
| **Orchestrator-workers** | the *model* decides who to delegate to, and when | `subagents` + `spawn_subagent`/`spawn_subagents` | [delegation.rb](delegation.rb) |

## The one decision that matters

**Who chooses the next step — your code, or the model?**

- **Your code chooses → a `workflow`.** Deterministic, inspectable, testable. The
  run is durable (its id *is* a Task), the I/O is schema-validated at the edges,
  and it is discoverable over HTTP (`GET /v1/workflows`). Reach for this whenever
  the shape of the work is known in advance.
- **The model chooses → `subagents`.** Flexible, and it costs a model call to
  decide. Reach for this when the work depends on what the user actually said.

They compose: a workflow step can `ask` an agent that itself delegates to
subagents. Start with a workflow and hand the choice to the model only where the
choice is genuinely open.

## Notes

- Every `ctx.ask` is **its own turn** — a separate Task, visible in the Studio
  and the trace. Nothing is hidden inside a black box.
- `ctx.gather` runs blocks concurrently on the turn's reactor and returns the
  values **in order**; wall-clock is the slowest branch, not the sum.
- Model output is *not* deterministic. These scripts print what came back; the
  useful thing to watch is the **structure** (how many turns, in what order, with
  what fan-out), which is what the engine guarantees.
