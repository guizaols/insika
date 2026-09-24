# Insika versus RubyLLM and its ecosystem

Date: 2026-09-22. Scope: the `codex/rubyllm-2-migration` working tree, installed RubyLLM 2.0.0, official documentation and ecosystem source. Insika is in development, not production. The findings below describe the original audit; execution status follows separately. Existing migration edits predate this audit.

## Execution status

Status reviewed 2026-09-24: the external MCP candidate below has been replaced by
RubyLLM's native MCP at commit `099c381b44fec6f1d72b2b63b9a9eea7635755f1`.
The Origin patch is removed. Streamable HTTP and stdio are covered by local
protocol fixtures; legacy SSE configuration must migrate to Streamable HTTP.
Latest full suite: 5,616 examples, zero failures (seed 7551); Studio: 53 tests
passed with rebuilt assets. Tools are grouped by origin/server, filterable and
collapsible, with per-section selection that respects denied tools.
See [current verification and remaining work](../../RUBYLLM_2_MIGRATION.md#verification).
The 2026-09-24 repeated benchmark still fails the proposed 10% gate: catalog
p50 +10.3-22.1%, peak RSS +26.8%; no runtime safety or accounting was disabled.
The comparison tables below retain the ecosystem assessment made on 2026-09-22.

Implemented with regression tests:

- Replaced both generic JSON validators with JSONSchemer, declared directly in the gemspec. Fixed workflow `false` validation. Tool scalar leniency and top-level blank handling remain; explicit nulls and declared constraints now follow JSON Schema. Remote schema references cannot fetch external resources.
- Account native chat aggregates across tool rounds and failed attempts, taking deltas for continued chats. Export native recorded cost and failed/cancelled-turn usage. Preserve unknown values. Correct the custom negotiated-rate adapter's disjoint cache arithmetic.
- Preserve the historical internal input/output subtotal because budgets and evals already add separate cache buckets. Correct the Responses HTTP projection to inclusive input/total. The original audit's blanket claim that the internal subtotal itself was erroneous was too broad; the conflicting pricing and external projection were the bugs.
- Remove retired MCP client, ingestor and command implementation. The old command name aliases live discovery. Existing stored snapshots are untouched; the live refresh result/event replaces the retired report/event, documented in TOOLS.md.
- Use native schemas and parsed responses in distill, harvest, knowledge extraction/consolidation and refinement. DeepSeek JSON-object mode uses an `items` envelope for arrays. Keep business validation; old injected text callables retain their compatibility parser.
- Make native transport the sole retry owner for reliable RubyLLM chats, using isolated configuration and zero outer retries. The user approved native per-request semantics and no same-model retry after streaming begins. Insika retains model rotation, session pins, model allowlists, tenant circuits and the overall per-model deadline. Circuits count exhausted sequences, not each HTTP attempt. Custom/non-native chat integrations retain the existing coordinator.
- Reuse ToolBatch in SteerInjector instead of maintaining another batch counter.
- Fix bounded speech reads: use the Net::HTTP request block and reject an oversized chunk before appending it.
- Add opt-in manual native compaction (`compaction.mode: native`) after commit, using filtered stored history and separate provider/model/protocol-bound state. Checkpoints retain the original prefix for fallback. Unsupported providers do not invoke a second compactor. Local budgeting remains conservative over both alternatives.

Executed gates that prevent further deletion today:

| Candidate | Evidence and remaining requirement |
| --- | --- |
| Speech transport | Native binary streaming buffers successful non-audio responses without yielding. An in-memory malformed-response probe buffered 16 KB with zero callbacks. Retain the bounded transport until native limits cover malformed/error bodies as well as audio. |
| Entire Reliability coordinator | Native transport retries are integrated with approved per-request semantics and exhausted-sequence circuit accounting. Native fallback restores the primary model before the next generation; model-bound compaction also needs a rebuilt prefix. Keep application fallback, output reset, tenant circuits and deadlines. Reliable turns checkpoint ungated tool results and flush failed redactor tails. Native `with_fallbacks` adoption remains incomplete. |
| Native approvals | Integrated for native chats through a read-only PendingActionStore resolver. Executor checkpoints stable calls before parking in the existing mailbox. Decisions bind to task, turn, call ID, real tool and arguments. Provenance, customer confirmation and authorization remain in Insika; no second queue was introduced. |
| Native compaction | Manual native integration is opt-in and tested through completed turns, checkpoint reload, model/provider/protocol changes, malformed responses, budget eviction and earlier custom history. Blanket Message#to_h persistence and automatic raw-state persistence remain excluded. No live-provider acceptance or performance gain is claimed. |
| Skills | Inspected released 0.3.0 requires RubyLLM `~> 1.12`; main-branch compatibility is not a released compatible pin. Keep the current loader until a compatible release passes scoping/hot-reload tests. |

Remaining work is explicit: native per-attempt event persistence across auxiliary operations, native fallback integration, the compatible skill-loader proof and any Rails durability comparison. No Rails rewrite, new gem extraction, upstream publication or speculative infrastructure was performed. Existing eval corpus, security boundaries and UI remain.

### Persistence proofs

`spec/insika/native_compaction_contract_spec.rb` exercises the installed OpenAI Responses implementation offline: manual compaction survives JSON reload, replaces only the wire prefix, retains original history, rejects unanswered tools, and remains present after a model switch. It also demonstrates raw-content redaction bypass and checks that Insika's current projection excludes that data. This is not a live-provider acceptance test.

The smallest safe compaction integration is to compact a fresh chat from sanitized persisted history after the turn commits, storing its result separately with the prefix boundary and provider/model/protocol binding. A fallback must reconstruct the retained original history instead of replaying an incompatible marker. Do not enable automatic raw-state persistence or run native and summary compaction together.

`spec/insika/native_approval_adapter_spec.rb` proves native resolver behavior with the existing pending-action store. `executor_native_approval_spec.rb` covers runtime approve/reject, cancellation, mismatched arguments and restart with pending/completed calls. Continuations preserve usage, evidence and filtered halt text; terminal side-effect metadata is recorded atomically with its spill ID. SQLite close/reopen and transaction rollback are covered in checkpoint store specs. Direct workflows keep the blocking gate. Legacy tool-name decisions cannot authorize new native call IDs. Operator approval timeout still aborts the turn without expiring its pending record; customer expiry is separate. Downstream idempotency remains necessary for a crash before the local side-effect marker.

The manual compaction adapter is opt-in; native operator approvals now run through the existing runtime. Native compaction currently reconstructs the full prefix and budgets both alternatives. A narrow, tested read of RubyLLM 2.0's private protocol field prevents replay across explicit protocol overrides; remove it when a public reader becomes available.

### Execution verification

- Native transport retry integration: Ruby 4.0.6, `bundle exec rspec --format progress --seed 32098`: **5,603 examples, 0 failures**, 52.63 seconds. Real transport fixtures verify exact attempts, no outer retry after streaming, context isolation, exhausted-sequence circuit accounting and tenant isolation. Native chat fixtures preserve completed writes and clean replacement output on application fallback. No live-provider calls.
- Retry/fallback safety fixes: Ruby 4.0.6, `bundle exec rspec --format progress --seed 32098`: **5,602 examples, 0 failures**, 53.51 seconds. Offline provider/transport fixtures; no live-provider validation.
- Retry/fallback investigation adds native model-restoration and per-attempt instrumentation contracts. Three regression cases reproduced lost ungated-write transcripts on retry/fallback and a failed stream's retained secret prefix consuming the replacement answer. Reliable turns now use the existing continuation checkpoint, and retry boundaries flush the old redactor tail. No dependency, parallel retry loop or new adapter was added.
- Native operator approval integration: Ruby 4.0.6, `bundle exec rspec --format progress --seed 32098`: **5,597 examples, 0 failures**, 55.08 seconds. Includes interruption/restart, recorded-write suppression, terminal-result recovery and checkpoint rollback. Offline tests only; no new browser or live-provider validation.
- Ruby 4.0.6, `bundle exec rspec --format progress --seed 32098`: **5,564 examples, 0 failures**, 55.06 seconds after native compaction integration. Existing duplicate-constant/intentional failure-path warnings and one RSpec deprecation remain.
- Native compaction review found and corrected explicit protocol override handling and deletion of earlier custom-provider history on the wire. Targeted re-review passed. Empty compaction output is also rejected before advancing the persisted boundary.
- Independent reviews covered schema/MCP/speech, accounting, structured factories, fallback policy and steering. Failed-turn usage export and provider-qualified allowlists for bare fallback IDs were corrected after review.
- `git diff --check` passes. Only the retired MCP file deletions were staged, because packaging enumerates tracked files; no commit or push was made. Prior migration edits remain intact.
- Offline real-Chat benchmark: `bundle exec ruby scripts/bench.rb --ruby-llm --iterations 300 --warmup 30 --concurrency 16 --waves 20 --json`. All three scenarios completed with zero errors; each ran 300 latency turns, 30 warmups and 320 throughput turns.

| Scenario | p50 / p95 ms | Turns/s |
| --- | --- | --- |
| Greeting | 1.37 / 2.06 | 633.9 |
| Two tool rounds | 1.77 / 2.32 | 488.9 |
| History | 1.58 / 2.14 | 595.6 |

This is one synthetic-provider run, not a controlled before/after measurement or a speedup claim. It does not supersede the earlier catalog-model comparison or clear the existing performance gate. No provider latency, browser verification or new Rails prototype was measured in this execution.

## Recommendation

Make Insika the smallest application runtime around RubyLLM, not another general-purpose agent framework. RubyLLM should own provider requests, model/tool execution, usage, pricing and supported request features. Insika should own only demonstrated application requirements: access, task lifecycle, configuration, persistence and delivery.

A custom implementation earns its place only when a reproducible contract test demonstrates a required behavior the alternative cannot supply more simply. Existing code, a plain-Ruby preference, hypothetical future scale and ecosystem immaturity without a specific incompatibility are not sufficient reasons. Do not split Insika into new gems before there is an actual second consumer or an accepted upstream contribution.

## Fix these first

1. **Accounting is incorrect for native 2.0 token buckets.** `Executor#usage_of` sums non-cached input and output, excluding cache reads/writes from the total. The main agent stage also reads the final response rather than every model attempt. `Telemetry::Pricing` assumes cached input is a subset of input, contrary to native 2.0 semantics. Use native usage/cost accounting; retain account attribution, persistence and budget enforcement.
2. **The custom workflow validator rejects a valid boolean.** `Workflow::Schema#check_object` uses `value[string_key] || value[symbol_key]`, turning `false` into `nil`. There are two homemade schema validators. Consolidate them on `json_schemer`, already installed through MCP, with an explicit direct dependency if core code uses it. Keep business validation separate.
3. **An obsolete MCP implementation remains wired.** `config/deployment.rb` registers `ImportMcpTools` with `McpHttpClient` and `McpToolIngestor`, despite its retirement comment. The HTTP import route already uses the live `refresh_mcp_tools` path. Remove the second protocol implementation after checking callers and previously imported development data; preserve necessary compatibility with a small command adapter, not another client.
4. **Speech generation bypasses the provider library.** `Media::Output.synthesize_speech` hand-builds an OpenAI HTTP request. Replace it with context-scoped native speech once byte-limit, cancellation, credentials and response-format contracts pass.

The first two findings were reproduced locally without network calls. The execution status above records the fixes and the internal-token-contract correction discovered while tracing all callers.

## Ownership comparison

Paths below are relative to the repository root. "Replace" means preserve the external behavior with contract tests, then delete the old mechanism, not run two implementations indefinitely.

| Insika responsibility | RubyLLM / ecosystem alternative | Decision and concrete remaining justification |
| --- | --- | --- |
| `executor.rb`: provider/tool loop | Native `ask_later`, `step`, `generate`, `run_tools`, `complete?` [1] | **Use native.** Migration already uses steps. Keep turn/task policy and API state transitions, not a second transcript state machine. |
| `tool_batch.rb`, `steer_injector.rb`, budget/loop tracking | Native tool-step boundaries [1] | **Simplify.** Three places infer batch completion. Apply interventions at completed steps where equivalent. Preserve per-tool budgets, sibling results, terminal halt and approval behavior. |
| `tool_envelope.rb`: concurrent tool execution | Native fiber concurrency and `tool_call:` identity [2] | **Delegate execution.** Keep read/write permissions and application-wide limits. Prefer explicit invocation identity to shared callback state. |
| `reliability.rb`, `provider_error_classifier.rb` | Native retries, typed errors and `with_fallbacks` [3] | **Replace provider mechanics.** Keep deadlines, tenant circuit state, allowed-model and pinned-model rules only where native behavior differs. Verify physical attempt counts and no repeated completed side effects. |
| `executor.rb`, `telemetry/pricing.rb`: usage and catalog arithmetic | Native token buckets, costs and `usage.ruby_llm` events [4] | **Replace.** Persist attempt-time native values, including incomplete/unknown data. Account/session budget windows remain application policy. Preserve a narrow negotiated-rate adapter until a supported native override is established. |
| Model resolution and provider configuration | Native model registry/capabilities [5] | **Keep selection policy, not another catalog.** Tenant allowlists and agent/session selection are application requirements. Make custom-model bypass explicit; do not infer that every configured provider needs `assume_model_exists`. |
| `schema_guard.rb`, `workflow.rb`: generic JSON validation | Installed `json_schemer` [6] | **Replace duplicate validators.** Define strict JSON semantics and explicit legacy coercion/blank-value rules. Native schema declarations alone do not validate every tool value at the trust boundary. |
| Distill, harvest, knowledge, refinement and eval JSON parsing | Native `with_schema` and `response.parsed` [7] | **Replace format parsing for supported models.** Keep evidence, ownership, confidence and domain constraints. Retain fallback parsing only for a demonstrated unsupported-provider case. |
| `mcp_http_client.rb`, `mcp_tool_ingestor.rb`, `commands/import_mcp_tools.rb` | Existing `ruby_llm-mcp` live integration [8] | **Remove the retired protocol path.** These three files total about 280 lines before compatibility changes. They are still registered, so do not label them unreachable dead code. |
| Current MCP client, registry and tool adapters | `ruby_llm-mcp` [8] | **Keep narrow adaptation.** Tenant credentials, egress rules, stdio opt-in and live configuration remain. Each upstream workaround needs a reproducer and removal condition. |
| `media.rb`: speech HTTP client | Native context speech API, streamed chunks and speech object [9] | **Replace transport.** Keep size limits, channel opt-in, credential isolation and API projection. Verify bounded allocation and stream abort rather than assuming a streaming callback guarantees them. |
| Image generation and transcription | Native paint/transcription APIs | **Continue delegating.** Keep safe inbound fetches, byte limits and response packaging. Passing untrusted URLs directly to a provider is not an equivalent security boundary. |
| `recovery.rb`, task/checkpoint stores, session scheduling | Durable Agents: ActiveRecord persistence, ActiveJob and optional continuations [10] | **Keep provisionally; compare the whole persistence path.** Native guide is not a drop-in SQLite store. Required evidence is task states, transactional claims, session ordering, restart recovery and delivery behavior, not avoidance of Rails. Both paths must address at-least-once external effects. |
| Operator approval and customer confirmation | Native approval resolver, pending calls, approve/deny [2] | **Prove native operator parking, then replace.** Keep authorization, persisted decisions, expiry and UI. Customer confirmation with a conversational response is not automatically the same workflow. |
| `workflow.rb`, delegation tools | Native agent steps and `RubyLLM.workflow` instrumentation [1] | **Use native execution; keep minimal application adapters.** Correlation scopes are not a durable job scheduler. Do not grow a competing workflow DSL. |
| `memory_store.rb`, memory context provider | Memory guide: application records, remember/recall and embeddings [11] | **Keep storage/access policy.** The guide expects application-owned memory. Tenant/customer scope, deletion, TTL and audit are concrete requirements; the current facts/recent-notes retrieval is not semantic search. |
| `compaction.rb` | Native `with_compaction` / `compact` [12] | **Native first, conditional fallback.** Unsupported providers, cross-provider portability or a measured lower-threshold need can justify custom summaries. Never run both compactors on one conversation. |
| Chat history serialization and reload | Native message state; Rails persistence preserves native fields [10][12] | **Required compatibility work.** Current serialization/reload projects a limited message shape and can lose opaque compaction state. Prove round-trip preservation before enabling native compaction or changing durable execution. |
| `context/builder.rb`, context providers | Native chat/request controls [12] | **Keep explicit context allocation only.** Pinned identity, permissions, memory and skill priorities are application requirements. Do not duplicate provider message rendering. |
| `skill_catalog.rb`, `tools/load_skill.rb`, skill providers | `ruby_llm-skills`: discovery, directory/database sources, lazy loading [13] | **Run a replacement proof.** Keep tenant permissions and hot-edited/versioned skill records if needed. Verify a released 2.0-compatible pin; main-branch features and ecosystem listings are not release guarantees. |
| Prompt catalog and agent packs | Native ERB rendering; ecosystem Registry [14] | **Use native rendering when needed.** Pack configuration, authorization and hot-editing are not just prompt templates. Do not add a second prompt store without removing the first. |
| `telemetry.rb`, recorder and model/tool spans | Native plain-Ruby instrumenter [15] | **Delegate model/request/usage events.** Keep application task, policy, storage and delivery events, filtering sensitive fields. Avoid parallel instrumentation emitting duplicate spans or costs. |
| `evals/*` | Tribunal [16] | **Candidate, currently dependency-blocked.** Inspected gemspec excludes RubyLLM 2. Keep the domain corpus and side-effect/replay assertions regardless of runner. A compatibility contribution is more useful than creating another generic eval gem. |
| Validation retries / business guards | Contract [17] | **Do not adopt now.** Inspected gemspec excludes 2.0 and adds another Step abstraction. It is not a reason to retain generic homemade JSON validation. |
| Token estimator | Native provider token counting; Tokenizer [18] | **Keep the small heuristic for local fragment allocation until accuracy fails a measured requirement.** It is not billing. Provider counting adds requests and is not universally supported; Tokenizer adds native dependencies. |
| Knowledge retrieval / indexing | Native embeddings; Turbovec [19] | **No new vector engine now.** Current lexical retrieval and vector search are not equivalent. Adopt an established index only when a retrieval test demonstrates the need; keep tenant filters and deletion guarantees. |
| Automatic harvest, distill and refinement | Native structured outputs and application-specific memory recipes [7][11] | **Require quality/cost evidence.** Lack of a drop-in gem does not establish product value. Freeze expansion; retain only behavior justified by representative evals. |
| `cron.rb`, `timezone.rb`, `schedule_engine.rb` | Standard scheduling libraries such as Fugit [20] | **Separate calendar calculation from task policy.** Replace the custom calendar only after dependency/size and DST tests establish a simpler solution. Keep durable due-claims, overlap and budget rules. No new scheduler framework is needed. |
| Safety, egress, sandbox, evidence checks | Provider moderation; TopSecret for PII substitution [21] | **Keep trust boundaries.** Moderation/PII redaction do not replace authorization, SSRF prevention, sandboxing or provenance. Evaluate redaction only with Async isolation and tool/stream/log tests. Regex checks do not establish complete prompt-injection protection. |
| Responses API, SSE, channels/outbox, Studio | RubyLLM is the underlying provider/agent library | **Keep the actual product surface.** Validate demand for each API/UI feature instead of retaining it merely because it exists. Delivery and tenancy behavior are not supplied by a chat API. |
| A2A protocol integration | No equivalent SDK evaluated in this audit | **Unresolved.** Do not claim a justified custom protocol implementation from the absence of an evaluated alternative. Compare maintained SDKs before expanding it. |

## Durability and memory: the important distinction

The durable guide is a real alternative for execution plus persistence, but adopting it involves a framework/storage decision. Because there is no production migration to protect, a bounded comparison is reasonable: take one existing restart/approval/tool-side-effect scenario and implement it using the documented Rails path. Compare total deleted code, retained adapters, deployment dependencies, latency and memory. Adopt it if the whole solution becomes smaller and the required contracts pass. Do not fund a rewrite merely to evaluate this question.

Memory is different: the official guide explicitly expects application-owned records and tools. Retaining scoped storage is consistent with the ecosystem; retaining every custom summarizer, extractor and ranking rule without quality evidence is not.

Native compaction is a third, separate capability. Automatic behavior is provider-specific: Anthropic/Bedrock Mantle have a 50,000 minimum threshold, OpenAI/Azure Responses support thresholds, and OpenRouter can drop middle messages. Unsupported providers ignore the option. Manual compaction supports xAI and OpenAI/Azure Responses. Opaque compacted state is provider/model-bound. These differences must be tested against the actual configured providers and fallback path.

## Implementation order and acceptance gates

1. **Accounting and schema correctness.** Add failing specs for the reproduced bugs, multi-round tool usage, unknown costs and retries. Adopt native accounting and one JSON validator. Preserve public usage projection and budget behavior deliberately.
2. **Obvious duplicate transports and parsers.** Remove retired MCP protocol code; adopt native speech and structured responses. Pass credential isolation, byte limits, malformed responses and domain-evidence tests.
3. **Provider execution mechanics.** Replace retry/fallback mechanics and duplicate batch inference using native execution. Count real transport attempts; test streamed failures, pinned models, terminal tools, approvals and side effects before/after a failed generation.
4. **Conditional replacements.** Prove native compaction serialization, operator approvals and released skill-loader compatibility individually. Delete each old path when its replacement passes; retain only the specific unsupported case.
5. **Larger choices only with evidence.** Compare Rails durability if it can remove substantial application machinery. Contribute Tribunal/MCP compatibility fixes when they enable deletion. Do not create more gems or add a vector store speculatively.

Every step must run the affected contracts and then the full existing suite. Benchmark the same plain-Ruby workloads before and after, with the same model-registry behavior and request counts. No speedup is claimed by this audit. Previous green migration tests do not cover the accounting and boolean failures found here.

## Reproductions and verification limits

Read-only local probes produced:

```text
RubyLLM::Tokens(input: 10, output: 2, cache_read: 90, cache_write: 20)
Executor#usage_of => input_tokens: 10, output_tokens: 2, total_tokens: 12,
                    cached_tokens: 90, cache_creation_tokens: 20
Native buckets total => 122; inclusive input projection => 120

Workflow::Schema: required boolean property enabled, value {"enabled" => false}
Result => {"enabled" => ["must be boolean, got null"]}
JSONSchemer 2.5.0 with the same schema/value => valid
```

Inspection alone establishes API overlap, not full replacement equivalence. Ecosystem gemspec checks describe inspected source, not a successful installation matrix. Execution subsequently reproduced multiplied retries and added native continuation/approval/serialization contracts. No live-provider calls were made. Full-suite results are recorded with the execution verification below.

## Primary sources

1. [Agentic workflows](https://rubyllm.com/agentic-workflows/)
2. [Tool execution](https://rubyllm.com/tool-execution/)
3. [Error handling](https://rubyllm.com/error-handling/)
4. [Cost and usage tracking](https://rubyllm.com/cost-and-usage-tracking/)
5. [Models](https://rubyllm.com/models/)
6. [JSONSchemer](https://github.com/davishmcclurg/json_schemer)
7. [Structured output](https://rubyllm.com/structured-output/)
8. [RubyLLM MCP](https://github.com/patvice/ruby_llm-mcp), [maintainer fork](https://github.com/crmne/ruby_llm-mcp)
9. [Text to speech](https://rubyllm.com/text-to-speech/)
10. [Durable agents](https://rubyllm.com/durable-agents/)
11. [Memory](https://rubyllm.com/memory/)
12. [Chat request control and compaction](https://rubyllm.com/chat-request-control/)
13. [RubyLLM Skills](https://github.com/kieranklaassen/ruby_llm-skills)
14. [Prompt rendering](https://rubyllm.com/prompt-rendering/), [Registry](https://github.com/washu/ruby_llm-registry)
15. [Native instrumentation](https://rubyllm.com/instrumentation/), [OpenTelemetry adapter](https://github.com/thoughtbot/opentelemetry-instrumentation-ruby_llm)
16. [Tribunal gemspec](https://github.com/Alqemist-labs/ruby_llm-tribunal/blob/main/ruby_llm-tribunal.gemspec)
17. [Contract gemspec](https://github.com/justi/ruby_llm-contract/blob/main/ruby_llm-contract.gemspec)
18. [Native tokenization](https://rubyllm.com/tokenization/), [Tokenizer](https://github.com/washu/ruby_llm-tokenizer)
19. [Turbovec](https://github.com/washu/ruby_llm-turbovec)
20. [Fugit](https://github.com/floraison/fugit)
21. [TopSecret](https://github.com/thoughtbot/ruby_llm-top_secret)

Discovery index: [official RubyLLM ecosystem](https://rubyllm.com/ecosystem/). Inclusion in that index does not certify compatibility or behavioral equivalence.
