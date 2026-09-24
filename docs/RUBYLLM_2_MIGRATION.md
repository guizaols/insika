---
title: RubyLLM 2 Migration
parent: Ship it
nav_order: 6
permalink: /rubyllm-2-migration/
---

# RubyLLM 2 Migration

Status reviewed on 2026-09-24: implemented on `codex/rubyllm-2-migration`,
and **approved for merge and testing on the existing Railway staging service**.
Keep Insika's durable runtime and policy;
delegate provider protocols, tool schemas, and cache formatting to RubyLLM.
No Rails, package extraction or database migration. JSONSchemer is a direct
dependency for workflow and tool argument validation.

The follow-up [ecosystem audit and execution status](superpowers/plans/2026-09-22-rubyllm-ecosystem-audit.md)
records replacements and the concrete gates that still block others.

## Dependency

The Gemfile and lockfile pin RubyLLM commit
`099c381b44fec6f1d72b2b63b9a9eea7635755f1`, the merge of
[native MCP PR 959](https://github.com/crmne/ruby_llm/pull/959).
The external `ruby_llm-mcp` dependency and its Origin-header patch are removed.
The pinned source still reports version 2.0.0, but published 2.0.0 does not contain
this client. Before publishing Insika, require a released RubyLLM version with
native MCP in the gemspec and remove the Git pin. A gemspec cannot carry it.

Existing MCP records and cached tool descriptors remain readable. Discovery and
execution use native Streamable HTTP or stdio; Insika retains policy, evidence,
credential masking, the stdio opt-in, and the egress allowlist. Refresh preserves
the server's strict boolean read-only hint. Legacy SSE records fail with a request
to configure a Streamable HTTP endpoint; they are not silently rewritten. Native
MCP also requires HTTPS outside loopback, even with the HTTP egress opt-in.
Sampling, roots and server logging are not supported by the native client. Insika
does not yet expose native MCP input-request resumption or its OAuth UI; unanswered
input requests surface as tool errors through the existing wrapper.

Native MCP validation on 2026-09-23: **5,614 examples, zero failures**, seed 46560.
Local protocol fixtures cover real stdio and HTTP sockets, modern discovery,
legacy handshake/session headers, event-stream responses, authorization headers,
tool errors, structured content, attachments, and read-only metadata. No external
production MCP server was invoked for these fixture checks. The current-candidate
benchmark below was repeated after this dependency switch; it does not call MCP.

The official RubyLLM 2.0.0 coding skill is copied into `.agents/skills/rubyllm`.
Refresh it from the installed gem when upgrading RubyLLM, not from upstream main.

## Preserved Behavior

- Native `step` drives the existing runtime; a terminal tool finishes its batch
  and prevents another model request. Siblings, result IDs, steering, and output remain covered.
- Tools use `parameter` and `parameters_schema`; data-defined JSON schemas stay unchanged.
- Native cache markers preserve the stable/volatile Anthropic instruction boundary.
- Native tokens and model readers retain Insika's usage fields. Auxiliary billing
  includes cache reads and writes without counting thinking twice.
- RubyLLM now handles operator approval gating for native chats. Insika retains
  authorization, persisted decisions, customer confirmation, security checks and UI.
  Decisions bind to task, turn, call ID, real tool name and arguments. Checkpoints
  preserve pending calls, completed results, usage, evidence and filtered halt text.
  Recorded side effects are skipped on replay; terminal results survive interruption.
  Direct workflow/customer-confirmation paths retain the existing blocking gate.
  Legacy tool-name decisions do not authorize newly generated native calls.
  A crash between an external effect and its local marker still requires downstream
  idempotency; this is not an exactly-once guarantee.
- Opt-in native
  compaction now uses separate model-bound state and filtered stored history, with
  original-prefix recovery on fallback. See [native compaction](CONTEXT.md#native-responses-compaction)
  for its conservative budget and supported providers.

## Verification

Latest completed checks (2026-09-24, before merge): **5,616 RSpec
examples, zero failures**, seed 19184; **53 Studio tests passed**. Assets were
rebuilt during the preceding Studio implementation and remain unchanged.
Final diff review reran 200 focused runtime/MCP/contract examples with no failures
and found no actionable introduced regression in the reviewed scope.
Browser checks covered tool grouping by origin/server, filtering, collapsible
sections and section selection without changing other sections or denied tools.
Changes still require **Save tools**; filtering does not change permissions.

Local development validation also exercised a real provider reply and MCP tool
discovery. The user confirmed WhatsApp replies and execution through the Metabase
MCP. This is smoke-test evidence, not a comparative quality eval or a new benchmark.
An HTTP data tool and an MCP instance may use different credentials: successful
MCP discovery does not validate a separately configured HTTP tool.

### Earlier Verification

Native transport retries are enabled for reliable native chats, with isolated
per-chat configuration and no outer Insika retries. The approved behavior is
per-request retries, stopping once streaming starts. Insika still owns fallback,
model policy, tenant circuits and the overall per-model deadline. Circuits count
an exhausted native sequence once, not each internal HTTP failure. The native
request timeout is also configured from the profile. Completed tool results
survive fallback, and failed-stream redactor tails are discarded.
Native `with_fallbacks` adoption remains deferred: it restores the original model
before the next generation and requires adaptation for model-bound compaction.

After native compaction, operator approvals and native transport retries: **5,603 examples, zero failures** (seed 32098).
See the [execution record](superpowers/plans/2026-09-22-rubyllm-ecosystem-audit.md#execution-verification)
for the new contracts, remaining replacement gates and offline benchmark.

Full RSpec after the benchmark correction: **5,519 examples, zero failures**
(seed 55367). Studio: **50 tests passed** during the preceding migration validation.
The real-gem contract has 17 behavioral cases, with no missing-gem skip.
Synthetic SQLite records passed 1.16 write -> 2.0 read/write -> 1.16 read/write,
including history, pending/resolved approvals, and recorded side-effect markers.
An isolated installed gem passed reply, SQLite embed, Rack mount, actual HTTP/SSE,
Studio login, packaged assets/docs, and lazy-load guards using an offline provider.
That earlier install used the former external MCP Git dependency. On 2026-09-24,
the current native-MCP candidate was built and installed in a fresh GEM_HOME
outside the checkout and passed all those checks again. The synthetic SQLite
1.16 -> 2.0 -> 1.16 record rehearsal also passed again. A Linux ARM64 Docker
build with the deployment lockfile passed and loaded native MCP while preserving
the core lazy-load guard. The isolated gem install explicitly pins RubyLLM's Git
revision and resolves other allowed dependencies; it is not a public gem-install
proof or a substitute for verifying Railway's x86_64 deployment.
Browser checks passed for login, agent configuration, skill/provider creation,
Playground replies, completed tasks, and session transcripts. Approval/resume
flows were covered by automated tests, not separately exercised in the browser.

## Performance

### Current Candidate (2026-09-24)

Five alternating runs per version in each of three modes (stub, real Chat with
a synthetic model, and real Chat with catalog model `gpt-4o`), plus five SQLite
runs per version. The catalog experiment was subsequently corrected and rerun
five times per version, as described below. Ruby 4.0.6,
arm64-darwin25, YJIT off; 300 latency turns, 30 warmups, concurrency 16 and
20 waves per scenario. Native MCP and the latest Studio changes are present.
The same existing benchmark harnesses load each checkout's actual runtime.

All 40 benchmark processes succeeded: 58,500 engine turns including warmups,
matching provider/tool/history/chunk counts, and 300,000 SQLite writes with zero
reported lock errors. Automated suites ran after the measurement. Development
servers remained running, so workstation noise is not eliminated.

Profiling exposed a flaw in the earlier catalog experiment: its flag assertion
wrapped `RubyLLM.chat`, but `main` constructs chats through a context. Its
`assume_model_exists: false` override therefore did not reach the actual Chat.
Those earlier catalog numbers do not establish equivalent registry behavior.
The corrected local harness forces the option at `Chat#initialize` and asserts
that the resulting model is the exact registry object. The separate profiler
confirms one registry lookup per measured turn in both versions.

All ten corrected benchmark processes succeeded, with matching activity counts
across 19,500 additional turns including warmups. Median corrected measurements:

| Scenario | Main p50 / p95 ms | Migration p50 / p95 ms | Turns/s, before -> after |
| --- | --- | --- | --- |
| Greeting | 1.37 / 2.01 | 1.48 / 2.48 | 654.1 -> 603.8 |
| Two tool rounds | 1.46 / 2.10 | 1.80 / 2.42 | 603.5 -> 515.7 |
| History | 1.51 / 2.08 | 1.62 / 2.25 | 573.9 -> 558.2 |

Catalog p50 increases are **7.3-23.3%**, or **0.11-0.34 ms per turn**.
Peak RSS increased **13.9%** (87,769,088 -> 99,991,552 bytes), and tool
allocations increased 8.4%. Tool p50 ranges did not overlap (main 1.35-1.58 ms,
migration 1.65-1.85 ms); the other scenarios' ranges overlap. These are new runs,
so differences from the invalid comparison are not attributable solely to the
harness correction. Synthetic-model p50 increased 18.3-28.2% and peak
RSS 29.4%. Stub p50 changes were -5.3%, +4.5% and +9.1%, with peak RSS +2.3%.
SQLite median writes/s stayed within 2.3% of baseline in either direction.

The proposed 10% gate still fails numerically. This isolates an increase along the real-Chat
path, not its cause; it does not measure native HTTP, MCP calls, UI speed or
provider latency. No safety or accounting was disabled. Earlier measurements
below are retained as historical comparisons, not current acceptance evidence.

**Decision (2026-09-24):** The project owner accepted the measured performance
tradeoff for this migration and approved continuing with RubyLLM 2's native
runtime. The additional 0.34 ms in the two-tool benchmark does not block ongoing
development validation. This is an explicit exception, not a passing benchmark
or acceptance of future regressions. There are no real operational workflows
beyond the tests already executed. Continue validation with the existing
automated tests, controlled integration checks and offline benchmarks. Measure
live latency, errors and memory when actual usage exists; that is not a current
development prerequisite. Investigate
upstream improvements with isolated evidence; do not add custom caches or a
replacement tool loop without demonstrated waste. The performance decision alone
did not authorize deployment. The project owner subsequently authorized merge
to `main` and testing through its automatic Railway staging deployment. Gem
publication remains outside that authorization.

### Targeted Profiling (2026-09-24)

Three alternating instrumented runs per version, each with 1,001 measured
two-tool turns after 30 warmups, completed without errors. Both versions made
one registry lookup, three provider calls and two tool calls per measured turn.
The probe wraps selected methods using the monotonic clock and `GC.stat`; it is
local diagnostic tooling, not a runtime dependency.

Median inclusive time per turn, rounded, across those instrumented runs:

| Scope | Main ms | Migration ms |
| --- | --- | --- |
| `Executor#ask_on` (generation and tool cycle) | 0.402 | 0.659 |
| `Executor#create_chat` | 0.261 | 0.279 |
| `Executor#record_model_visible` | 0.011 | 0.042 |
| `Executor#persist_turn` | 0.326 | 0.322 |
| `ContextBuilder#call` | 0.251 | 0.267 |

The largest observed increase is inside the generation/tool cycle. Native
`instrumentation_payload`, `record_completion_event`, and
`record_out_of_band_usage` account for approximately 0.030, 0.022 and 0.038 ms
per turn respectively. The latter is the offline provider's fallback accounting
path, not the accounting path used by native HTTP providers. Message creation
also grows from approximately 0.063 to 0.079 ms for the same 55 messages/chunks
per turn. These nested times overlap other scopes and must not be added to them.

Registry lookup is slower (approximately 0.073 -> 0.111 ms), but native 2.0
creates one connection per turn instead of 1.16's two; the overall Chat creation
difference is much smaller. The trace increase includes corrected behavior:
`main` treats the tool Hash as pairs and misses schemas, whereas the migration
captures actual tool schemas and system instructions. Removing those records
would reintroduce a correctness problem, not provide an equivalent optimization.

Instrumented timings include probe overhead and cannot apportion the exact
uninstrumented regression. Instrumented allocation counts are not clean
allocation measurements. RSS growth remains unattributed; MCP and HTTP were not
exercised. The next investigation should isolate RubyLLM's per-round bookkeeping
without Insika before proposing an upstream optimization. Keep accounting,
approval checks and trace correctness intact; no custom tool loop or cache was
added during profiling.

### Earlier Catalog-Model Experiment (Invalid Flag Assertion)

These results used the ineffective `RubyLLM.chat` assertion described above.
They are historical only, not an equivalent-registry comparison. Five
alternating runs per version named `gpt-4o`. The offline provider is
registered under `openai` only inside the experiment; it does not make HTTP calls.
Its intended assertions were bypassed by context-created chats. No application
model-selection behavior was changed.
Settings match the earlier comparison: Ruby 4.0.6, YJIT off, 300 latency turns,
30 warmups, concurrency 16, 20 waves, and identical tool/history/chunk counts.
Every scenario in all ten runs completed without errors.

| Scenario | 1.16 p50 / p95 ms | 2.0 p50 / p95 ms | Turns/s, before -> after |
| --- | --- | --- | --- |
| Greeting | 1.23 / 1.65 | 1.32 / 2.06 | 549.2 -> 629.2 |
| Two tool rounds | 1.36 / 1.75 | 1.62 / 2.09 | 620.3 -> 539.8 |
| History | 1.28 / 1.78 | 1.44 / 1.95 | 590.6 -> 561.9 |

Median p50 changes are +7.3%, +19.1%, and +12.5%. Median peak RSS is
89,194,496 -> 105,971,712 bytes (+18.8%); tool allocations rise 4.8%.
These numbers cannot determine whether registry lookup avoidance explains the
difference. They are offline engine-plus-Chat results, not
live-provider latency or proof of a RubyLLM defect. Investigate the remaining
tool-loop and memory differences before making an upstream performance claim.

### Earlier Unknown-Model Experiment

The following results are retained for comparison, not generalized to catalog
models. The fake model used `assume_model_exists: true`, which bypassed registry
resolution in 1.16 but not 2.0.

Five interleaved runs per version, Ruby 4.0.6, YJIT off, same host and settings.
Real Chat with a synthetic provider, no network; provider/tool/chunk/history counts match.

| Scenario | 1.16 p50 / p95 ms | 2.0 p50 / p95 ms | Turns/s, before -> after |
| --- | --- | --- | --- |
| Greeting | 1.38 / 1.83 | 1.60 / 2.23 | 476.3 -> 571.2 |
| Two tool rounds | 1.35 / 1.95 | 1.79 / 2.44 | 619.8 -> 491.5 |
| History | 1.34 / 1.87 | 1.78 / 2.37 | 597.3 -> 498.2 |

These replace the initial measurements: the offline provider omitted request
`model_info`, unlike native `Accounting::Usage::Tracker#succeed`. Supplying it
removes three spurious pricing catalog lookups per two-tool turn. The benchmark
spec now rejects those lookups. No production runtime workaround was added.

Corrected real-Chat p50 increased 15.9-32.8%; peak RSS increased 24.0%
(87,310,336 -> 108,232,704 bytes); tool allocations increased 7.4%.
RSS also increased 11.3% in stub mode, so the entire memory difference cannot
be attributed to RubyLLM catalog loading. SQLite had zero lock errors, but
throughput varied from +1.6% to -17.2%; the earlier no-regression claim is withdrawn.
These are host-specific samples, not a controlled attribution of every difference.

The standalone `scripts/rubyllm_profile.rb` reproduces the fixture defect and
the remaining catalog lookup without Insika. With `--request-context --profile`,
1,000 two-tool turns make 1,000 `Models#find` calls in 2.0 versus none in 1.16.
RubyLLM 2 resolves catalog metadata even with `assume_model_exists`; 1.16 skipped
it for this non-local provider. In one instrumented run that lookup consumed
112 ms total; fallback usage accounting consumed 39 ms. Inclusive timings must
not be summed. All three requests, both tools, history and aggregate tokens are
checked. The fake provider bypasses native transport and uses fallback usage
accounting, so this is not an end-to-end native-provider performance claim.

For upstream discussion, run the script outside Bundler with `1.16.0 --profile`
and `2.0.0 --request-context --profile`. Omitting `--request-context` deliberately
recreates the old fixture defect, not native provider behavior. The useful upstream
question is whether repeated registry resolution can be cheaper while preserving
model metadata and refresh semantics. No upstream patch or issue was published;
remaining latency and memory attribution is open.
The proposed 10% performance gate **failed**. No accounting or safety was disabled.
Reproduce the candidate with the commands in [Benchmark](BENCHMARK.md).

## Release Gate

Public gem release still requires a published RubyLLM native-MCP dependency.
The measured performance tradeoff is accepted; current installed-artifact and
synthetic record-compatibility checks passed. Merge to `main` and testing of its
automatic Railway staging deployment are authorized. Confirm that deployment's
status and HTTP behavior before reporting success. No production rollout,
database schema migration or gem publication is part of this validation.
Record compatibility does not guarantee exactly-once external effects; keep
destination idempotency or reconciliation for an execution-before-checkpoint failure.
