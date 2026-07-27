# Why Insika

**Ruby is ready for production AI.** The narrative that you must reach for Python
to ship serious LLM applications is out of date. [RubyLLM](https://rubyllm.com)
gave the language a first-class, provider-agnostic LLM client — chat, tools,
streaming, embeddings, moderation — a genuinely valuable foundation that closed
the "Ruby can't do AI" gap. Insika is the next layer up: it takes those
primitives and makes an agent *dependable in production*.

Because **an agent without a harness is just a chat loop.** The model does the
reasoning, but everything that makes an agent survive contact with real traffic —
durable state, tools, guardrails, evals, operations — lives in the engine around
it. Those harnesses exist, mature, for other ecosystems. Ruby teams have mostly
been told to glue libraries together. They shouldn't have to.

Insika is an **agent runtime for Ruby**: the turn pipeline, the operational
surface, and the safety layer, in one deployable piece — behind an
OpenAI-Responses-compatible API. It stands on RubyLLM for the provider layer and
adds everything between a chat call and a production agent.

And it does it *ergonomically*. A complete, running agent is a few lines of Ruby —
the same speed-to-first-agent story Python teams tell, without leaving Ruby:

```ruby
require "insika"

agent = Insika.agent("assistant") do
  model "deepseek-chat"
  provider :deepseek
  instructions "You are a concise, friendly assistant."
end

puts agent.reply("hi, what can you do?")   # one turn, in-process
agent.serve                                 # ...or a full server: /studio + /v1/responses
```

Every capability below is reachable the same way — see [`examples/`](../examples/),
one small runnable project per capability.

## Four ways to run an agent

There are, roughly, four ways to put an LLM agent into production. They're not
wrong — they're different amounts of "build it yourself":

- **Raw SDK loop.** Call the provider SDK directly and hand-roll the
  reason→act→observe loop. Minimal to start; everything operational is on you.
- **Assemble a framework.** Compose library pieces — a tool abstraction here, a
  memory store there, your own persistence and moderation. Flexible, but you own
  the integration and the gaps between the parts.
- **Hosted agent gateway.** A managed service runs the agent behind an API. You
  get operations for free, but your agents, prompts, and conversation data live in
  someone else's system.
- **An agent runtime (this project).** The loop, durability, tools, safety, and an
  operations UI as one thing you deploy in your own infrastructure.

How they compare on what production actually demands:

| | Raw SDK loop | Assemble a framework | Hosted gateway | **Insika (runtime)** |
|---|:---:|:---:|:---:|:---:|
| Get a first agent talking | ✅ | ⚠️ | ✅ | ✅ |
| Add/change a tool without a redeploy | ❌ | ❌ | ⚠️ | ✅ |
| Durable, resumable turns (crash mid-conversation) | ❌ | ⚠️ | ✅ | ✅ |
| Content-safety guardrails built in | ❌ | ⚠️ | ⚠️ | ✅ |
| Evals / regression gating as a primitive | ❌ | ⚠️ | ⚠️ | ✅ |
| Operations UI included | ❌ | ❌ | ✅ | ✅ |
| Runs in your infrastructure (you own the data) | ✅ | ✅ | ❌ | ✅ |
| One container, no orchestrator to start | ✅ | ⚠️ | — | ✅ |

✅ built in · ⚠️ possible, but you build/integrate it · ❌ not addressed · — n/a

## What we do differently

- **Tools are data, not code.** Define a tool with a JSON Schema manifest and a
  declarative binding, and the running agent picks it up — no rebuild, no redeploy.
  Import whole toolsets from an MCP server or a manifest at runtime. In most setups
  a new tool is a code change; here it's a row.
- **Durability is the default.** Every turn checkpoints; sessions and tasks recover
  across restarts; continuous replication is one env var away, with a documented
  restore drill. If the box dies mid-conversation, the conversation doesn't.
- **Safety is built in, not bolted on.** Input guardrails (prompt-injection and
  abuse handling that fails gracefully *without* burning a model turn), content
  moderation, PII/secret redaction in the output stream, and a post-turn validator
  — configured, not hand-rolled, and opt-in per agent.
- **Evals are a primitive.** Golden conversations, LLM-as-judge, and baseline
  gating run against the *same* API your users hit — so a prompt or model change
  that regresses behavior fails loudly before it ships.
- **An operations UI is included.** Studio lets an operator manage agents, tools,
  approvals, and traces — pause a task, approve a sensitive action, inspect a
  tool-call trace — without writing code. Headless when you want it, operable when
  you need it.
- **One container, one file.** SQLite in WAL mode with streaming replication. No
  queue cluster, no orchestrator, no managed database required to start — and it
  runs a real production workload today.
- **Fibers, not a thread per request.** An LLM turn is almost all *waiting* on the
  provider. Insika runs on the [Async](https://github.com/socketry/async) fiber
  scheduler and serves under [Falcon](https://github.com/socketry/falcon), so one
  process handles thousands of concurrent turns on a handful of connections instead
  of pinning a heavyweight thread per call. This is exactly the model
  [RubyLLM's async guide](https://rubyllm.com/async/) recommends — *"Falcon is a
  Ruby application server built on fibers; with Falcon, async just works"* — and it
  composes for free, because RubyLLM's HTTP cooperates with Ruby's fiber scheduler.
  It's a big part of why one box goes so far.
- **The engine gets out of the way.** On top of that concurrency, all the machinery
  above adds **well under a millisecond of overhead per turn**; a single process
  sustains thousands of turns per second of pure engine work. A neutral,
  provider-free benchmark in the repo reproduces it with one command — see
  [BENCHMARK.md](BENCHMARK.md). The rest of a turn's latency is the model, not us.
  *(That number is engine overhead only — end-to-end latency is provider-bound and
  not claimed here.)*

## When a lighter tool is the right call

Insika is for when an agent has to run **unattended, durably, and safely, in
production**. If that's not you yet, reach for less:

- If you only need LLM calls with tools in Ruby and nothing operational around
  them, **[RubyLLM](https://rubyllm.com) alone is excellent** — and it's exactly
  what Insika builds on. Reach for Insika when "nothing operational around them"
  stops being true: when the agent has to run unattended, recover from crashes,
  enforce safety, and be operable by someone who isn't you.
- If your team is committed to another language ecosystem, use a runtime native to
  it — the ideas here travel, the code doesn't.
- If you want a minimal terminal coding assistant rather than a product platform,
  a single-purpose CLI agent will be simpler.

## See also

- [README](../README.md) — quickstart and the drop-in `/v1/responses` API.
- [BENCHMARK.md](BENCHMARK.md) — the neutral, reproducible engine benchmark.
- [OBSERVABILITY.md](OBSERVABILITY.md) — OpenTelemetry tracing (opt-in).
