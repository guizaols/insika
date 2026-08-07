---
title: Architecture
parent: Understand the idea
nav_order: 2
permalink: /architecture/
---

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
flowchart TD
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
  monotonic `seq`, so one stream multiplexes many turns and replays reliably. Not
  every event is for the end user — see the edge contract below.

### What crosses the edge

A turn is not one assistant message. Between the user's message and the answer the
model may narrate the tool loop ("let me look that up"), apologise for a tool that
failed, or — when it has no tool to call — reason in prose. All of it arrives as
ordinary content chunks, indistinguishable at the token level from the answer.

So the engine publishes rather than relays: **`:content` carries the answer — the
text of the assistant message that *ends* the turn**. It is emitted once, whole,
when that message ends. Everything else the model says rides `:intermediate`, and
the provider's own reasoning channel rides `:thinking`. Both are real events —
the Studio renders them and the trace keeps them, which is how an operator sees
what the model was doing — and `/v1/responses` deliberately translates neither.

Two consequences worth knowing before you build on it:

- The customer-visible stream is per **message**, not per token. A consumer that
  accumulates deltas gets the same text; one that renders them live gets it in one
  piece. Watch `:intermediate` if you want the keystrokes.
- A turn that dies mid-message publishes nothing. Half a sentence was never an
  answer; the fragment is still on the stream for whoever is debugging it.

That contract is what makes a channel possible at all. A
[channel](CHANNELS.md) whose recipient is not on the connection — a WhatsApp
number, your own callback URL — cannot stream anything: it needs one message it
can send. `:content` is that message, which is why a channel delivers exactly it
and nothing else.

The exception is `halt_when`: a tool that ends the turn has already answered the
customer, so the model's lead-in before that call *is* the turn, and it is
published as the answer.

**Neither default is a law.** A product with a "thinking" panel wants the
reasoning, and a chat UI may want the progress line. An agent opts a channel in:

```ruby
edge_stream thinking: true, intermediate: false
```

Two things keep that from re-opening the hole. Nothing crosses unless someone
opted in, per agent. And what crosses gets its **own frame type**, never the
answer's — `response.reasoning_summary_text.delta` for reasoning, and a namespaced
`insika.intermediate.delta` for the narration, because the Responses protocol has
no honest event for "assistant text that is not the answer" (there, that text *is*
`output_text.delta`, told apart only by an output-item index this adapter does not
carry). So a consumer that accumulates `output_text` deltas into one message —
WhatsApp — is unaffected by the switch, and one that renders reasoning has
something to render.

## A turn, end to end

The Executor runs a fixed sequence of stages. Each stage boundary drains the
mailbox, so a cancel or pause is honored at a safe point — never mid-write. One of
those boundaries sits **between the provider's last word and publishing the answer**:
a turn cancelled while the model was working publishes nothing, so what the customer
read and what the transcript holds never disagree.

The numbers are the engine's own — the same stage numbers `executor.rb` uses. The
sequence has no stage 7; the numbering is kept as the code has it rather than
renumbered here.

```mermaid
flowchart TD
  s1["1 · Command Bus<br/>send_message → Task on a fiber, task_id returned"]
  s2["2 · Context Builder<br/>providers, budget, pinned"]
  ck["initial checkpoint<br/>the state at the START of the turn"]
  s3["3 · Policy Engine<br/>allowed tools/skills, approval tags"]
  s1 --> s2 --> ck --> s3 --> mw

  subgraph mw ["4 · Middleware wraps everything below — edge limit → input guardrail"]
    s5["5 · assemble chat"]
    s6["6 · agent interaction<br/>chat.ask + tool-loop"]
    s8["8 · Persistence<br/>checkpoint → session → task"]
    s9["9 · Response<br/>task_completed + usage"]
    s5 --> s6 --> s8 --> s9
  end

  s9 --> hook["after-task hook<br/>output guardrail"]
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

When a step contains several tool calls they are executed **one at a time**, unless
the agent raised `limits[:tool_concurrency]` — then the batch runs on the turn's
reactor with at most that many in flight, one fiber per call, and the envelope's
shared semaphore is the cap. A turn with an approval-required tool always runs
serially. See [Tools](TOOLS.md#parallel-tool-calls) for what that changes.

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
flowchart TD
  subgraph manifest [Manifest path]
    m["POST /v1/tools/manifest"] --> sub["substitute<br/>{{env.*}} / {{secret.*}}"]
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
flowchart LR
  start(( )) -->|send_message| running[running]
  running -->|turn persisted| checkpointed[checkpointed]
  checkpointed -->|next turn| running
  running -->|approval required| waiting[waiting]
  waiting -->|approve_action| running
  running -->|process killed| crashed[crashed]
  crashed -->|boot recovery / resume_task| running
  checkpointed -->|task_completed| completed[completed]
  completed --> done(((  )))
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
  root1[minimal wiring] --> phase1
  root2[server deployment] --> phase1

  subgraph phase1 [Phase 1 · spine — infra, identical across roots]
    backend["backend<br/>SQLite (INSIKA_DB) or Memory"] --> dstores[domain stores<br/>session · task · checkpoint · memory]
    reg[registries<br/>tools · workflows · policies]
    caps[capability registry]
    es2[event stream]
    hk[hooks]
  end

  phase1 ==>|"Graph.build(spine:)"| phase2

  subgraph phase2 [Phase 2 · build — assembled on the spine]
    cbz[Context Builder] --> exz[Executor]
    pez[Policy Engine] --> exz
    mwz["Middleware<br/>edge limiter → input guardrail"] --> exz
    exz --> busz[Command Bus<br/>6 core commands]
  end
```

Everything in phase 1 is passed into phase 2: the domain stores, registries,
capability registry, event stream and hooks are all constructor arguments of the
Executor and the Command Bus (`spine.*` throughout `Graph.build`). The arrow is one
call, not one wire.

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
| Inbound queue (one turn at a time per session, and what happens to a message that arrives while one is running) | `lib/insika/session_actor.rb`, `lib/insika/queue_policy.rb`, `lib/insika/steer_injector.rb` |
| Channels (a way in and out for people; the reply that travels after the turn ends) | `lib/insika/channel_registry.rb`, `lib/insika/channels/*`, `lib/insika/channel_delivery.rb`, `lib/insika/outbox_store.rb`, `lib/insika/inbound_log.rb` |
| Tools (data/manifest/MCP) | `lib/insika/tool_definition.rb`, `tool_manifest.rb`, `mcp_tool_ingestor.rb` |
| Plugin loading (boot) | `lib/insika/plugin.rb`, `lib/insika/plugin/loader.rb` |
| Refinement (traffic → report) | `lib/insika/refinement/*`, `lib/insika/refinement_store.rb` |
| Evals (cases, judges, gate) | `lib/insika/evals/*`, `lib/insika/golden_store.rb`; `evals/run.rb` is the CLI |
| HTTP/SSE surface | `server/*` |

## See also

- [Agents](AGENTS.md) · [Tools](TOOLS.md) · [Skills](SKILLS.md) ·
  [Context](CONTEXT.md) · [Channels](CHANNELS.md) · [Plugins](PLUGINS.md) ·
  [Security](SECURITY.md) — the capability guides.
- [Evals](EVALS.md) — the cases that grade an agent, and the pre-merge gate.
- [Refinement](REFINEMENT.md) — reading a live agent's own traffic back as a report.
- [Deploy](DEPLOY.md) — running the engine durably.
- [Benchmark](BENCHMARK.md) — the per-turn engine overhead, reproducible.
