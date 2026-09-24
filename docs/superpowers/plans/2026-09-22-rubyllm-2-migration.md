# RubyLLM 2.0 Migration Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Track completion with the checkboxes below.

**Goal:** Run all existing Insika capabilities on RubyLLM 2.0, preserve practical deployment and operation, and remove duplication where measurements and behavior tests support it.

**Architecture:** Keep Ruby, Async, Falcon, SQLite, and Insika's existing persistence and public interfaces. Upgrade the RubyLLM boundary first; then simplify individual mechanisms using upstream APIs. Rails remains an option for a separate, measured proposal, not a prerequisite for this migration.

**Tech Stack:** Ruby >= 3.3, RubyLLM 2.0 with native MCP, Async, Falcon, SQLite, RSpec, existing Studio tooling.

**Spec:** The user's request: prioritize performance and practicality, keep everything already built working, and improve/refactor where useful. This document is the execution plan; it does not authorize production rollout or publishing.

**Execution status (2026-09-24):** Runtime migration uses RubyLLM commit `099c381b44fec6f1d72b2b63b9a9eea7635755f1` with native MCP; the external MCP gem and Origin patch are removed. Latest full RSpec: 5,616 examples, zero failures (seed 19184); Studio: 53 passing tests. Local provider, WhatsApp and Metabase smoke checks succeeded. The benchmark exceeds the 10% threshold, with an explicit project-owner exception. Current installed-artifact and synthetic SQLite compatibility proofs passed. Merge and automatic Railway staging deployment are authorized for testing; deployment verification remains required. Publishing still requires a released native-MCP dependency. See [results](../../RUBYLLM_2_MIGRATION.md).

Benchmark update (2026-09-24): repeated five alternating runs per version/mode
after native MCP and Studio changes. All runs passed their correctness checks,
then corrected the catalog harness during profiling and repeated its five runs.
Corrected catalog p50 increased 7.3-23.3% and peak RSS 13.9%; the 10% gate still
fails. Profiling points primarily to the generation/tool cycle; no runtime
optimization has been applied. Earlier catalog assertions missed context-created chats.
The installed-artifact proof and synthetic record rollback were repeated
successfully on 2026-09-24 with native MCP. See the current migration report.

Decision (2026-09-24): the project owner explicitly accepted the measured
performance tradeoff for this migration. Continue with RubyLLM 2's native
runtime and validate with the existing tests and controlled integration checks.
No operational workflows exist beyond the tests already executed; real-usage
measurements are future work, not a current development prerequisite. The 10% benchmark failure
remains recorded; this exception does not cover future regressions or authorize
merge, deployment or publication by itself. The project owner subsequently
authorized merge to main and its automatic Railway staging deployment for tests,
but not gem publication. Investigate upstream improvements without
adding custom caches or a replacement tool loop absent demonstrated waste.

## Constraints

- Read README.md, docs/ARCHITECTURE.md and CONTRIBUTING.md before implementation. Preserve one pipeline and agents configured through AgentProfile data.
- Preserve public DSL, packs, stored JSON, API/SSE event semantics, Studio workflows, and deployment configuration. Do not introduce a second runtime or permanent dual RubyLLM-version adapter.
- Preserve lazy loading, per-graph credentials, tenant isolation, evidence checks, approvals, customer confirmation, egress rules, cancellation, and serial writes per session.
- No feature removal or default change to make the upgrade easier. A failed equivalence check keeps the current mechanism or blocks the migration.
- Keep the existing database path, including /data/harness.db. Plain Ruby skips RubyLLM's Rails migrations; Insika still needs old-record compatibility tests.
- No new dependency or gem extraction without a concrete need. Reuse RSpec, existing fixtures, benchmarks and provider stubbing patterns.
- No speedup claim before measurement. Distinguish engine overhead, RubyLLM overhead, provider latency, and task completion quality.

## Baseline Evidence (2026-09-22)

| Finding | Consequence |
| --- | --- |
| insika.gemspec excludes RubyLLM 2.0; Gemfile.lock selects 1.16.0 | This is a migration, not a dependency-bound edit. |
| Locked ruby_llm-mcp 1.0.1 requires ruby_llm ~> 1.9 | Resolve a compatible MCP dependency before committing to the upgrade. |
| Executor and tools depend on Tool::Halt; ModelSelection uses with_params | Adapt stopping and request configuration without changing visible behavior. |
| ChatBuilder constructs Anthropic cache content; usage readers use 1.x fields | Check cache placement and accounting, not just method availability. |
| Most runtime tests use FakeChat; ruby_llm_contract_spec checks the real gem | Both test layers must pass; updating doubles alone proves nothing. |
| scripts/bench.rb uses a deterministic chat stub and an in-memory store | It cannot by itself demonstrate RubyLLM 2.0 or SQLite performance. |
| ToolEnvelope executes a tool before recording its side effect | Preserve deduplication of recorded calls; do not promise exactly-once external effects. |

Sources: [stable upgrade guide](https://rubyllm.com/upgrading/), [tool execution](https://rubyllm.com/tool-execution/), [durable agents](https://rubyllm.com/durable-agents/), [prompt caching](https://rubyllm.com/prompt-caching/), [ecosystem](https://rubyllm.com/ecosystem/). Use stable docs and the actual resolved gem source; /next includes unreleased changes. Dependency availability must be rechecked at execution time.

## 1. Freeze Behavior and Measure the Baseline

**Files:** spec/insika/ruby_llm_contract_spec.rb, spec/support/fake_chat.rb, scripts/bench.rb, spec/scripts/bench_spec.rb; reference docs/BENCHMARK.md and docs/RELEASING.md. Save generated evidence under ignored docs/internal/rubyllm-2/.

- [x] Start an isolated codex/rubyllm-2-migration branch from main. Record the source commit, Ruby/YJIT, OS, lockfile and benchmark settings; keep a runnable baseline checkout.
- [x] Run the full suite and identify existing failures or skipped integration coverage before edits. Require the real installed RubyLLM in the contract run; absence of RubyLLM::Chat must fail the migration check rather than silently skip it.
- [x] Record five baseline runs of the engine benchmark and the SQLite benchmark on the same machine. Preserve raw results, not only averages.
- [x] Extend scripts/bench.rb with an opt-in real-RubyLLM mode using a deterministic local provider/transport stub, following existing test patterns. Exercise a streamed reply, two tool rounds and history replay through the real Chat. Do not stub Chat or change the default benchmark. Cover the mode in spec/scripts/bench_spec.rb.
- [x] Measure that mode on 1.16 before migration. Include provider-call count, token/result counts and completion state so a broken shortcut cannot appear faster. Capture allocations with GC.stat and process peak RSS using the host's process measurement tool.

```bash
bundle exec rspec
bundle exec ruby -rruby_llm -e 'abort "real Chat required" unless defined?(RubyLLM::Chat); require "rspec/core"; exit RSpec::Core::Runner.run(["spec/insika/ruby_llm_contract_spec.rb"])'
bundle exec ruby scripts/bench.rb --iterations 300 --warmup 30 --concurrency 16 --waves 20 --json
bundle exec ruby scripts/bench_store.rb 1,2,4 2000
```

**Gate:** A reproducible baseline with real-gem coverage and a written behavior checklist. Baseline defects are recorded separately, never hidden by loosening tests.

## 2. Resolve Dependencies and Map the Changed API

**Files:** insika.gemspec, Gemfile.lock, lib/insika/mcp_client.rb, spec/insika/mcp_client_spec.rb, spec/insika/ruby_llm_contract_spec.rb.

- [x] Validate native MCP from merged RubyLLM PR 959 using local stdio/HTTP fixtures, including legacy handshakes, errors, attachments and strict read-only hints. Earlier external-gem compatibility experiments are historical evidence only.
- [x] Replace the temporary external MCP candidate with the tested immutable RubyLLM commit. No local compatibility patch remains required; public release dependency resolution is separate unfinished work.
- [x] Inventory RubyLLM call sites and inspect the installed 2.0 source, including background metering, media, tool schemas, caching, concurrency, callbacks and model configuration.
- [x] Update constraints and lockfile together: RubyLLM ~> 2.0.0 with the native-MCP Git pin; remove ruby_llm-mcp. This resolves for development, not public gem installation.
- [x] Read and install the official skill from the resolved RubyLLM 2.0.0 gem into .agents/skills/rubyllm for Codex. No Rails persistence or runtime dependency was added.
- [x] Remove OriginHeaderFix. Native MCP sends no Origin header in the local HTTP contract test.

```bash
rg -n 'RubyLLM|with_params|Tool::Halt|Content::Raw|input_tokens|output_tokens|cached_tokens|cache_creation_tokens' lib spec/support
bundle exec rspec spec/insika/mcp_client_spec.rb spec/insika/mcp_http_client_spec.rb spec/insika/mcp_live_tool_spec.rb spec/insika/mcp_tool_registry_spec.rb
```

**Gate:** Compatible dependency resolution and a complete call-site map. This task's dependency edits stay on the migration branch until tasks 3 and 4 pass; they are not an independently deployable release.

## 3. Adapt the Runtime Without Changing Its Contract

**Files:** lib/insika/model_selection.rb, lib/insika/chat_builder.rb, lib/insika/executor.rb, lib/insika/tools/data_defined_tool.rb, lib/insika/tools/present.rb, lib/insika/tools/stuck_signal.rb, lib/insika/tool_batch.rb, lib/insika/steer_injector.rb, lib/insika/turn_budget.rb, lib/insika/media.rb, lib/insika/telemetry/recorder.rb; other concrete callers found in task 2. Update their mirrored specs and spec/support/fake_chat.rb, spec/support/stubs/ruby_llm.rb, spec/support/smoke/shims/ruby_llm.rb.

- [x] Reproduce removed APIs against the real gem and replace private-source assertions with 17 behavioral contract tests.
- [x] Replace request configuration with native output limits and provider options; cover custom DeepSeek thinking and provider routing.
- [x] Replace Tool::Halt with an Insika result marker and the public step loop. Preserve halt_when, say, stuck signals and no additional model call after the terminal batch.
- [x] Verify terminal tools finish siblings and persist every result ID, with steering only at valid batch boundaries and existing serial-write rules intact.
- [x] Adapt tool schemas, keyword calls and history restoration; preserve Insika's persisted records and public fields.
- [x] Adapt token/model readers, including media and auxiliary billing; test cache reads/writes without double-counting thinking.
- [x] Use native cache markers and verify the actual Anthropic system blocks retain the identity/volatile boundary.
- [x] Update doubles and assert their runtime methods exist on the real gem.

```bash
bundle exec rspec spec/insika/ruby_llm_contract_spec.rb spec/insika/model_selection_spec.rb spec/insika/chat_builder_spec.rb spec/insika/executor_output_spec.rb spec/insika/executor_stuck_spec.rb spec/insika/executor_steer_spec.rb spec/insika/turn_budget_spec.rb spec/insika/executor_cache_spec.rb spec/insika/media_spec.rb spec/insika/telemetry
```

**Gate:** Identical observable outcomes for deterministic scenarios, including errors and terminal tools. Migration performance is measured here before optional refactoring begins.

## 4. Prove Existing Features and Stored State Still Work

**Files:** existing mirrored specs under spec/insika, especially integration/kill_restart_resume_spec.rb, integration/multi_worker_boot_recovery_spec.rb, commands/resume_task_spec.rb, tool_envelope_approval_spec.rb, tool_envelope_confirmation_spec.rb, tool_write_safety_spec.rb, tool_concurrency_spec.rb, embed_spec.rb and server/responses_spec.rb. Extend existing fixtures/helpers only where coverage is missing.

| Contract | Required evidence |
| --- | --- |
| Sessions, tools and recovery | Load records produced by the baseline; resume queued/interrupted/paused/waiting work; preserve recorded tool results and side-effect markers. Include forced process termination and both memory/SQLite paths. |
| Approvals and customer confirmation | Pending requests survive restart; rejection, cancellation, expiry, changed arguments and repeated confirmation retain their current guarantees. |
| Concurrency and steering | Same-session FIFO and serial writes, independent-session overlap, tool caps/timeouts, pause/cancel/interrupt and steer at valid batch boundaries. |
| HTTP and channels | Frozen Responses/SSE types, usage and event ordering; final versus intermediate/thinking output; outbox retry/delivery and existing channel capabilities. |
| Config and isolation | DSL/pack round trips, hot edits, scoped skills/tools, per-agent policy, two embedded graphs with separate credentials and tenant data. |
| Agent capabilities | Memory, knowledge, compaction, routing/fallbacks, workflows, subagents, media input/output, artifacts, schedules and follow-ups. |
| Improvement workflows | Snapshot evals, judges, refinement, facts and skill harvesting retain stored formats and review gates. |
| Security and loading | Egress, sandbox, evidence/provenance and guardrail checks still execute; load guards pass with the installed gems. |

- [x] Pass the synthetic SQLite 1.16 -> 2.0 -> 1.16 read/write rehearsal for sessions, history, checkpoints, pending/resolved approvals and side-effect markers.
- [x] Run the complete suite: latest 5,616 examples, zero failures. Missing real RubyLLM fails the contract suite instead of skipping it.
- [ ] Finish the browser approval/resume rehearsal. Earlier installed-gem browser checks passed login, agent config, skill/provider creation, Playground reply, completed task and session transcript/context. Latest checkout browser checks cover grouped/filterable/collapsible tools and section selection; 53 frontend tests pass and assets were rebuilt. Approval/resume passed automated tests only.
- [ ] Run the established eval corpus with unchanged prompts, models, tools and seeds against both revisions. Offline assertions are mandatory; live-provider quality comparisons are a separate release check with available credentials and a bounded sample. Report unrun cases explicitly.
- [x] Add a fault-injection regression for the execution-before-checkpoint window. Document that uncertain external effects require destination idempotency or reconciliation; do not claim a transaction around SQLite makes remote effects exactly once.

```bash
bundle exec rspec
npm --prefix lib/insika/studio test
```

**Gate:** No unexplained behavior regression, no lost stored state, no weakened security check. Any newly discovered safety defect is isolated and fixed before release, not counted as intended migration behavior.

## 5. Simplify Only Where It Pays

**Files:** only the existing modules proven redundant by tasks 2-4, with their mirrored specs. Candidate areas: ChatBuilder caching, ModelSelection provider mapping, Executor usage collection and MCP compatibility code.

- [ ] Compare each candidate with the stable upstream primitive. Record lines/mechanisms removed, dependencies added, behavior differences and before/after measurements. Make one independently reviewable change per concern.
- [x] Prefer native cache/options/usage APIs; retain Insika session accounting and policy enforcement.
- [x] Keep Insika approvals: RubyLLM's parked Chat alone does not replace durable pending actions, customer confirmation or the policy UI.
- [x] Keep skills, evals, memory and context assembly. No ecosystem package replacement or gem extraction was justified.
- [x] Run five interleaved baseline/candidate sets with matching feature counters, Ruby/YJIT and settings; archive latency, throughput, allocations, peak RSS and SQLite measurements.
- [x] Apply the proposed 10% thresholds: automatic acceptance still FAILED after correcting the context-bypassed catalog flag assertion and repeating five runs per version. Real-Chat p50 +7.3-23.3%, tool throughput -14.5%, peak RSS +13.9%. Earlier catalog results are invalid for equal-registry comparison. Full latency and memory attribution remains open. No safety/accounting was disabled to improve the benchmark.
- [ ] Validate SQLite and a local HTTP/SSE service as well as the in-memory benchmark. Reuse scripts/loadtest_session.rb only with an isolated fixture deployment that supports its documented seven-message flow; it is not a generic live-production load test.

**Gate:** Same behavior plus less maintenance or measured improvement, with no unexplained performance regression. Keep optional optimizations in separate commits so they can be reverted without undoing compatibility.

## 6. Package, Rehearse Rollback and Release

**Files:** CHANGELOG.md, README.md, docs/ARCHITECTURE.md, docs/DEPLOY.md, docs/RELEASING.md, docs/BENCHMARK.md only when supported results change; lib/insika/version.rb at release time. Follow the existing install-proof workflow.

- [x] Run full Ruby, Studio and real-gem contract tests plus the benchmark comparison; record results in docs/RUBYLLM_2_MIGRATION.md. Passing correctness does not override the failed performance gate; the project owner separately accepted this migration's measured tradeoff on 2026-09-24.
- [x] Historical artifact proof: built and installed outside the checkout with the former external MCP Git dependency. Verified reply, serve/Studio/SSE, Rack mount, SQLite embed, packaged assets/docs and lazy-load guards. This was a development artifact proof, not public gem-install resolution.
- [x] Repeat the installed-artifact proof after native MCP and the final Studio changes: fresh GEM_HOME, current RubyLLM Git pin, reply, SQLite embed, Rack mount, HTTP/SSE, Studio, docs/assets and lazy-load guards passed. Deployment-lockfile Linux ARM64 Docker build and native-MCP load also passed.
- [x] Rehearse record-level rollback on synthetic SQLite after both versions wrote records; preserve the original checkout and lockfile. Deployment/process rollback remains a separate release rehearsal.
- [ ] Drain active turns and use a consistent SQLite backup for deployment rehearsal. Do not serve both runtimes against the same production sessions during the initial switch. Preserve pending approvals and work rather than dropping them to simplify deployment.
- [ ] Propose a limited rollout with error rate, task completion, duplicate-write reports, queue latency, p95 and memory monitoring. Roll back on correctness regressions or sustained unexplained performance deterioration. Use a compatible rollback artifact; never restore an old backup over new writes without reconciliation.
- [x] Update the migration report, benchmark docs, plugin example, release gate, changelog and durability limits. No version bump, publish or deploy.

**Completion criteria:** The current native-MCP candidate passed installed-artifact and synthetic record-compatibility proofs on 2026-09-24. The measured performance tradeoff is explicitly accepted. Merge and Railway staging validation are authorized; verify the automatic deployment before claiming it works there. Continue controlled validation using existing tests; real-usage performance and quality measurements wait until operational workflows exist. Published dependency resolution remains a separate publishing requirement.
