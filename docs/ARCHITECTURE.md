# Architecture

This is the engineering reference — how a turn actually runs, why the pieces are
shaped the way they are, and where to look in the code. It is deliberately
separate from the [capability guides](AGENTS.md); those tell you *how to use* the
runtime, this tells you *how it works*.

Five principles run through everything below:

1. **RubyLLM does the model work.** Chat, streaming, the tool-loop, and provider
   retries are never reimplemented — the engine is the operational shell around
   them.
2. **One pipeline.** Every conversational turn goes through the *same* ordered
   stages. There is no fast path that skips policy or persistence.
3. **Everything is a Command.** Every state-changing interaction is a typed
   command through one bus; reads go straight to the stores, never through the
   runtime.
4. **Durable by default.** Every turn checkpoints; a killed process resumes from
   the last checkpoint on reboot.
5. **Config over code.** Agents, tools, skills, and policies are data in stores,
   editable hot — not classes you redeploy.

## The engine at a glance

A request enters as a Command, becomes a Task running on its own fiber, and streams
its progress out through the Event Stream as it moves down the pipeline.

```mermaid
flowchart LR
  client([HTTP client]) -->|"POST /v1/responses"| bus[Command Bus]
  bus -->|turn command| task[Task actor<br/>Async fiber]
  task --> cb[Context Builder]
  cb --> pol[Policy Engine]
  pol --> mw[Middleware<br/>edge limit · input guardrail]
  mw --> ex[Executor<br/>chat + tool-loop]
  ex --> rll[(RubyLLM ⇄ provider)]
  ex --> persist[Persistence<br/>checkpoint · session · task]
  task -.emits.-> es[Event Stream]
  es -->|SSE| client
  cb -.reads.-> stores[(SQLite stores)]
  persist -.writes.-> stores
```

- **Command Bus** validates and dispatches. A *turn* command (`send_message`,
  `trigger_workflow`) creates a Task and returns its id immediately; the result
  flows out on the Event Stream. A *control* command (`create_session`,
  `cancel_task`, `pause_task`, `approve_action`, `resume_task`) acts on stores
  synchronously. Queries are **not** commands — they read the stores directly.
- **Task actor** is an `Async` fiber with a minimal mailbox (`cancel`,
  `user_message`, pause). Because an LLM turn is almost all *waiting* on the
  provider, one process runs many concurrent turns on a fiber scheduler instead of
  pinning a thread per call.
- **Event Stream** is in-process pub/sub. Every event carries `task_id` and a
  monotonic `seq`, so one stream multiplexes many turns and replays reliably.

## A turn, end to end

The Executor runs a fixed sequence of stages. Each stage boundary drains the
mailbox, so a cancel or pause is honored at a safe point — never mid-write.

```mermaid
sequenceDiagram
  participant C as Client
  participant B as Command Bus
  participant X as Executor
  participant CB as Context Builder
  participant P as Policy Engine
  participant M as Middleware
  participant L as RubyLLM/provider
  participant S as Stores

  C->>B: send_message(agent, session, input)
  B->>X: create Task (fiber), return task_id
  X->>CB: build context (providers, budget, pinned)
  CB-->>X: context package
  X->>S: initial checkpoint (start of turn)
  X->>P: decide (allowed tools/skills, approval tags)
  P-->>X: resolution
  Note over X,M: Middleware wraps the rest:<br/>edge limit → input guardrail
  M->>X: proceed (or graceful halt)
  X->>L: assemble chat + ask (stream)
  L-->>C: content deltas (SSE, via Event Stream)
  L->>X: tool call(s) → tool-loop
  X->>S: persist (checkpoint → session → task)
  X-->>C: task_completed (usage)
```

The order is not arbitrary:

- **Context before policy.** The prompt is assembled first so policy can see what
  the turn will actually contain (candidate skills come from the catalog, tools
  from the registry).
- **The initial checkpoint is written before the model call.** "The checkpoint of
  turn *n* holds the state at the *start* of turn *n*." Without it, a crash during
  the model call would orphan the task with no checkpoint — unrecoverable.
- **Middleware wraps the model-facing stages**, so the edge limiter and input
  guardrail run *before* the provider is ever touched — a flood or an injection is
  refused without a paid model call.
- **Persistence is a fixed order** (checkpoint → session → task) and a pure drain
  point: the last stage never suspends, so a checkpoint is never left half-written.
- **Output validation** runs as an after-task hook on the produced content
  (the output guardrail).

## The tool-loop

Stage 6 is the single agent interaction. RubyLLM owns the reason→act→observe loop;
the engine wraps each tool the model may call in a **ToolEnvelope** that enforces
the per-tool timeout, records side-effects for checkpointing, skips
already-completed side-effects on resume, and fires the approval gate.

```mermaid
flowchart TD
  ask[chat.ask -> model] --> dec{tool call?}
  dec -->|no| done[final content]
  dec -->|yes| env[ToolEnvelope]
  env --> appr{approval<br/>required?}
  appr -->|yes| suspend[[suspend turn<br/>await operator]]
  suspend --> appr
  appr -->|no / approved| kind{tool kind}
  kind -->|code| ruby[Ruby class<br/>in-process / sandbox]
  kind -->|data / MCP| egress[EgressGuard] --> http[(external HTTP)]
  ruby --> obs[result -> back to model]
  http --> obs
  obs --> ask
```

A **data tool** is config, not code (see [Tools](TOOLS.md)): its result comes back
to the model exactly like a code tool's, but it went out over HTTP through the
egress guard. A tool exception is caught and returned *to the model* as an error
result — it does not crash the turn. Side-effecting tools (POST and friends) are
recorded in the checkpoint so a resume does not re-run them.

## Ingesting tools: manifest and MCP

Tools become data in the store through two runtime paths, both hot (no restart):

```mermaid
flowchart LR
  subgraph manifest [Manifest path]
    m["POST /v1/tools/manifest"] --> sub["substitute {{env.*}} / {{secret.*}}"]
    sub --> val1[validate each tool]
  end
  subgraph mcp [MCP path]
    srv[(MCP server<br/>HTTP transport)] --> ing[MCP ingestor]
    ing --> conv[each tool → HTTP data tool<br/>JSON-RPC tools/call]
    conv --> val2[validate]
  end
  val1 --> store[(ToolStore)]
  val2 --> store
  store --> cat[reload catalog + registry]
  cat --> loop[available in the tool-loop]
```

The manifest path is the **only** one that resolves `{{env.*}}` (at ingestion);
every other write path requires a literal URL. Partial failure on the manifest
path is isolated — one malformed tool is reported in `errors[]` while the rest
import. See [Tools](TOOLS.md#registering-a-tool).

## Durability: checkpoints and resume

The runtime has no external job queue. Durability is stores plus **boot recovery**:
at startup the recovery scan finds tasks that were mid-flight and resumes each from
its last valid checkpoint — the *same* code path a `resume_task` command uses.

```mermaid
stateDiagram-v2
  [*] --> running: send_message
  running --> checkpointed: turn persisted
  checkpointed --> running: next turn
  running --> waiting: approval required
  waiting --> running: approve_action
  running --> crashed: process killed
  crashed --> running: boot recovery / resume_task
  note right of crashed
    resume replays from the last
    checkpoint; completed
    side-effects are skipped
  end note
  checkpointed --> completed: task_completed
  completed --> [*]
```

Resume always replays from the *start of the last checkpointed turn*. Tool calls
that already completed in the interrupted turn are recorded in the checkpoint and
**not** re-executed, so a non-idempotent side-effect fires at most once. A resumed
turn is also never re-counted against edge-limit ledgers. Cancellation is
cooperative — checked at stage boundaries, never in the middle of a store write.

## Composition root

The whole graph is wired in one place — `Insika::Wiring::Graph` — in two phases,
so the two deployment roots (a minimal in-process wiring and the full server
deployment) share the parts that are identical and layer on only what genuinely
differs.

```mermaid
flowchart TD
  subgraph phase1 [spine — infra, identical across roots]
    backend["backend<br/>SQLite (INSIKA_DB) or Memory"]
    backend --> dstores[domain stores<br/>session · task · checkpoint · memory · …]
    reg[registries<br/>tools · workflows · policies + builtins]
    caps[capability registry]
    es2[event stream]
    hk[hooks]
  end
  subgraph phase2 [build — assembled on the spine]
    cbz[Context Builder]
    pez[Policy Engine]
    mwz["Middleware<br/>(edge limiter → input guardrail)"]
    exz[Executor]
    busz[Command Bus<br/>6 core commands]
  end
  phase1 --> phase2
  dstores --> exz
  reg --> pez
  es2 --> exz
  hk --> exz
  cbz --> exz
  pez --> exz
  mwz --> exz
  exz --> busz

  root1[minimal wiring] --> phase1
  root2[server deployment] --> phase1
```

`backend_from_env` picks the backend: `INSIKA_DB` set → durable SQLite (the
prerequisite for recovery); unset → ephemeral in-memory (dev/demo). Registering the
operator commands (`pause_task`, `approve_action`) in the shared core is what lets
both roots expose the Studio's controls without a per-root patch. The guardrails
factory contributes the input guardrail as the single middleware and the output
validator as the after-task hook, so both roots enforce content safety identically.

## Where the code lives

| Concern | Code |
|---------|------|
| Composition root | `lib/insika/wiring/graph.rb` |
| Command bus + handlers | `lib/insika/command_bus.rb`, `lib/insika/commands/*` |
| Turn pipeline | `lib/insika/executor.rb` |
| Context assembly | `lib/insika/context/*` |
| Policy | `lib/insika/policy/*` |
| Stores | `lib/insika/stores/*`, `lib/insika/*_store.rb` |
| Recovery | `lib/insika/recovery.rb` |
| Tools (data/manifest/MCP) | `lib/insika/tool_definition.rb`, `tool_manifest.rb`, `mcp_tool_ingestor.rb` |
| HTTP/SSE surface | `server/*` |

## See also

- [Agents](AGENTS.md) · [Tools](TOOLS.md) · [Skills](SKILLS.md) ·
  [Context](CONTEXT.md) · [Security](SECURITY.md) — the capability guides.
- [Deploy](DEPLOY.md) — running the engine durably.
- [Benchmark](BENCHMARK.md) — the per-turn engine overhead, reproducible.
