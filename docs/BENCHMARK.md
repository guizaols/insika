---
title: Benchmark
parent: Operate
nav_order: 6
permalink: /benchmark/
---

# Benchmark — engine overhead, neutral & reproducible

This is the engine's public performance benchmark. It is **neutral** (no
competitor, no baseline, no product-specific deployment appears), **reproducible**
(one command, no API key), and **provider-free** by design. It measures the one
thing the engine actually controls: the overhead the engine adds around the
model on every turn.

Run it:

```bash
bundle exec ruby scripts/bench.rb
```

No key, no service, no network. It forces the in-memory backend, so it never
touches a real deployment's data.

## What it measures — and what it does not

A turn's wall-clock time is dominated by the **provider round-trip** — the LLM
generating tokens — which the engine does not control and cannot speed up.
Profiling a real turn put the engine's own local assembly at well under a
millisecond and time-to-first-token entirely bounded by the provider. A
benchmark that called a provider would therefore:

- require an API key — **not reproducible** by a third party;
- name a model/endpoint as its baseline — **not neutral**;
- bury the engine signal under provider and network noise.

So this suite replaces the model with a **deterministic in-process stub** and
reports only the engine's contribution:

| Metric | Meaning |
|---|---|
| **total** (p50/p95) | per-turn engine latency — all engine work, no model call |
| **prep** (p50/p95) | context build + policy + guardrail detectors + chat assembly |
| **ttft** (p50/p95) | assembly → first streamed token, engine-side |
| **gen** (p50/p95) | streaming the rest through the pipeline (filter/emit/event stream) |
| **throughput** | turns/s a single process sustains at a given concurrency |
| **pipeline overhead** | engine work per streamed token (µs) |
| **allocations** | Ruby objects allocated per measured turn, including benchmark driver bookkeeping, excluding warmup |

**Out of scope, on purpose:** end-to-end latency, time-to-first-token *against a
provider*, and tokens/s of *model generation*. Those are provider-bound — the
Insika has no lever on them — so this suite makes no claim about them.

The stub implements exactly the chat surface the executor touches, and each turn
runs the full engine path: context build, policy resolution, guardrail
detectors, chat assembly, tool-call callbacks, streamed output, persistence,
checkpointing, and the event stream. The default mode replaces RubyLLM's Chat;
use `--ruby-llm` below to include the real Chat and tool execution.

## Scenarios

The agents are synthetic — built through the public `Insika.agent { … }` DSL and
imported the same way any pack is, so the measured path is the real one.

- **greeting** — a minimal turn: a short system prompt, no tools. Baseline
  engine overhead.
- **tool_call** — a turn simulating one tool call; exercises tool assembly and
  call/result callbacks without executing the tool.
- **multi_turn** — a one-shot carrying prior conversation messages; shows how
  overhead moves as the context the engine assembles grows.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--scenario NAME` | `all` | `greeting`, `tool_call`, `multi_turn`, or `all` |
| `--iterations N` | `200` | measured turns in the latency pass |
| `--warmup N` | `20` | unmeasured warmup turns |
| `--concurrency N` | `8` | concurrent turns per wave (throughput pass) |
| `--waves N` | `5` | waves in the throughput pass |
| `--identity-tokens N` | `2000` | approximate size of the agent's system prompt |
| `--history-turns N` | `10` | prior messages for the `multi_turn` scenario |
| `--output-tokens N` | `48` | tokens the stub streams per turn |
| `--json` | off | emit results as JSON (for regression gating) |
| `--ruby-llm` | off | run the real RubyLLM Chat with an offline provider |

`--json` prints the engine version, Ruby/YJIT status, the full config, and every
metric — a stable shape to diff across commits.

## Offline RubyLLM benchmark

```bash
bundle exec ruby scripts/bench.rb --ruby-llm --json
```

This opt-in mode measures the engine **plus RubyLLM's real Chat and tool loop**.
Only the provider is synthetic: it yields deterministic chunks without HTTP,
credentials, or a model service. The normal executor creates the Chat, assembles
its history and tools, and registers the production callbacks. The `tool_call`
scenario executes two sequential lookup rounds; `greeting` streams an answer and
`multi_turn` seeds the requested history before streaming.

JSON includes the RubyLLM version, `mode`, and per-scenario `ruby_llm_activity`
counts for provider calls, executed tools, history messages, and streamed chunks.
Activity counts include warmup; allocation measurements exclude warmup and cover
both measured passes. Compare matching modes and settings across versions; the
default stub mode keeps its existing one-tool scenario. Neither mode measures
HTTP serialization, network latency, or actual model generation.

The offline provider supplies request `model_info`, as native RubyLLM 2 usage
tracking does. Omitting it adds spurious catalog lookups during cost accounting.
For an isolated, self-checking reproduction without Insika, run
`ruby scripts/rubyllm_profile.rb 2.0.0 --profile` and repeat with
`--request-context`. Use `1.16.0` for the old-gem comparison, outside Bundler.
Method timings are inclusive and must not be summed; use runs without `--profile`
for latency comparisons. This diagnostic still omits native HTTP processing.

## Reference numbers

For the five-run main versus RubyLLM 2 migration comparison repeated on
2026-09-24, see [current candidate results](RUBYLLM_2_MIGRATION.md#current-candidate-2026-09-24).
It uses this harness, plus the API-equivalent baseline harness, without YJIT.
The older YJIT reference below is not a migration acceptance result.

A reference run. **The absolute milliseconds are machine-specific** — reproduce
them on your own hardware with the command below; what travels across machines is
the shape (sub-millisecond overhead, flat p95, thousands of turns/s per process).

```
insika 0.1.0 · ruby 4.0.6 (YJIT) · Apple Silicon (arm64-darwin)
bundle exec ruby scripts/bench.rb --iterations 300 --warmup 30 --concurrency 16 --waves 20
```

| Scenario | total p50 | total p95 | prep p50 | throughput @16 | µs/token |
|---|---|---|---|---|---|
| greeting | 0.40 ms | 0.63 ms | 0.17 ms | ~1900 turns/s | 4.8 |
| tool_call | 0.39 ms | 0.69 ms | 0.16 ms | ~1670 turns/s | 4.6 |
| multi_turn | 0.38 ms | 0.64 ms | 0.16 ms | ~1700 turns/s | 4.4 |

Reading: the engine adds **well under a millisecond per turn** (p50 ≈ 0.4 ms,
p95 < 0.7 ms), and that overhead stays flat with a tool round-trip and with
accumulated context. A single process sustains ~1.7–1.9k turns/s of pure engine
work. The rest of any real turn's latency is the provider.

## Publication rule

**Any public claim about the engine's performance must reference this suite.**
Performance numbers produced against a specific provider, deployment, or competitor
are not publishable — they are neither neutral nor reproducible. If a performance
claim cannot be reproduced by running `scripts/bench.rb`, it does not go in public
materials.

The rule is about **performance**, which is what this suite measures. Claims about
what an agent *gets right* live in a different suite with a different contract: the
[cross-harness bench](CROSS-HARNESS-BENCH.md) needs a provider key, because a
commerce conversation cannot be stubbed, and it names other harnesses. It carries its
own publication rule, which is stricter about the rows it did not write.
