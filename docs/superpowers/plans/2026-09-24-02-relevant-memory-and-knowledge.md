# Relevant Memory and Knowledge Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Track progress with the checkboxes below.

**Goal:** Select more useful customer memories and learned knowledge for a question while retaining SQLite and current access boundaries.

**Architecture:** Retrieve a bounded candidate set using existing stores, then optionally reorder it with the graph's RubyLLM context. Keep lexical selection as the fallback. Measure quality, added latency, and reported cost before enabling reranking for production agents.

**Tech Stack:** Ruby, RubyLLM 2.0 reranking, existing SQLite/in-memory KV stores, existing context providers and evals.

**Spec:** The accepted scope below and [Context](../../CONTEXT.md).

## Accepted scope

Execute after [observability](2026-09-24-01-rubyllm-observability.md). Ship knowledge retrieval first, then opt-in customer-memory selection. The model provider performs reranking; SQLite stores the original records. No external vector database is needed.

The first release has no FTS5 migration, embeddings index, or vector extension. `Knowledge::Index.build` currently maps `fts5` to `Scan`; it is not an implemented FTS5 backend. Reranking cannot recover a concept excluded by lexical candidate selection. Record that limitation in eval results rather than claiming semantic recall is solved.

## Global constraints

- No new dependency. Reuse the configured graph's RubyLLM context, never global provider credentials.
- Reranking is off by default and enabled as profile/pack data; existing agents keep their behavior.
- Preserve `memory: true/false`; introduce a separate optional `memory_retrieval` hash rather than changing the boolean's meaning.
- Restrict candidates by agent/tenant or customer memory scope before calling a provider. Exclude expired/deleted records.
- Do not send secret material. Existing memory fencing, provenance, context budget, and retention rules still apply.
- String keys at the persistence boundary. All new behavior has mirrored specs; the full suite must pass.

## Existing implementation

- `Knowledge::Index::Scan#search(agent_id, query:, tenant:, top_k:)` ranks lexical overlap with confidence and recency.
- `Context::Providers::Knowledge` injects concept summaries and expands one link hop; `load_knowledge` loads bodies separately.
- `Context::Providers::Memory` currently injects all active facts plus ten recent notes.
- `MemoryStore.scope_for` defines customer, explicit-tenant, and session fallback scopes. Reuse the current provider's scope resolution exactly.

## Task 1: Add opt-in reranking to knowledge retrieval

**Files:** Modify `lib/insika/context/providers/knowledge.rb`, `lib/insika/agent_profile.rb`, `lib/insika/dsl/runtime.rb`, `config/wiring.rb`, and `config/deployment.rb` where their existing provider construction requires injection. Create `lib/insika/context/reranker.rb` and `spec/insika/context/reranker_spec.rb`; extend `spec/insika/context/providers/knowledge_spec.rb`, `spec/insika/agent_profile_spec.rb`, and `spec/insika/executor_knowledge_spec.rb`.

**Interfaces:** Proposed `Context::Reranker#select(query:, documents:, config:, top_k:)` returns validated indexes into the supplied documents, or `nil` for fallback. It receives the graph's LLM context on construction. Proposed pack shape:

```ruby
{
  "knowledge" => {
    "retrieve" => true, "top_k" => 5,
    "rerank" => {
      "provider" => provider_slug, "model" => registered_rerank_model_id,
      "candidate_limit" => 20, "timeout_seconds" => 2
    }
  }
}
```

`provider_slug` and `registered_rerank_model_id` are deployment-selected values verified against the installed registry and provider capabilities. Never assume the chat provider supports reranking.

- [x] Test omitted configuration preserves current results and performs no rerank call. Validate positive integer limits, `candidate_limit >= top_k`, a maximum of 100 candidates, positive timeout, and required model/provider. Reject invalid opt-in settings when loading a profile.
- [x] Add a ranking fixture where the best answer has lower lexical rank but is in the candidate set. Stub a native result with indexes `[2, 0]`; assert selected record identities follow that order. Add an unrelated-tenant record and assert its text is never sent.
- [x] Implement the public operation through the injected context:

  ```ruby
  result = llm.rerank(query, documents,
    provider: config.fetch("provider"), model: config.fetch("model"), top_n: top_k)
  indexes = result.results.map(&:index)
  ```

- [x] Validate every returned index is an Integer in range and is not duplicated. Invalid/empty output, provider error, or the configured Async timeout returns `nil`, restores lexical ordering, and records a sanitized warning. Empty input skips the provider entirely. Bound document size using the existing context budget/token estimation utilities before transmission; never send an unbounded concept body list.
- [x] Retrieve up to `candidate_limit` with the existing Scan, rerank name/description/body candidates, select `top_k`, then perform the existing one-hop expansion. Keep provenance labels and lazy body loading unchanged.
- [x] Emit operation diagnostics through plan 1 without raw candidate text. Account for rerank cost separately from chat usage and include it in an explicitly labeled total when known; preserve nil for unknown pricing. Avoid counting it twice through both return values and instrumentation.
- [x] Run `bundle exec rspec spec/insika/context/reranker_spec.rb spec/insika/context/providers/knowledge_spec.rb spec/insika/knowledge_index_spec.rb spec/insika/executor_knowledge_spec.rb spec/insika/agent_profile_spec.rb spec/insika/load_guard_spec.rb`. Commit as `feat(knowledge): add optional candidate reranking`.

## Task 2: Apply relevance selection to customer memory

**Files:** Modify `lib/insika/context/providers/memory.rb`, `lib/insika/agent_profile.rb`, `lib/insika/dsl.rb`, and both provider construction roots used in Task 1. Extend `spec/insika/context/providers/memory_spec.rb`, `spec/insika/agent_profile_spec.rb`, and existing DSL/pack round-trip specs. Add a bounded notes read to `lib/insika/memory_store.rb` only if its current `notes` method cannot supply the candidate limit.

**Interfaces:** Proposed `memory_retrieval` profile hash contains `top_k` and the same `rerank` hash as knowledge. Reuse `Context::Reranker#select`; keep `memory` as the activation gate. Stable identities are fact keys and note IDs, not text or positions saved across turns.

- [x] Add profile/DSL/pack round-trip tests for `memory_retrieval`; nil is the legacy behavior. Validate the same bounds as Task 1. The DSL generates data only.
- [x] Add customer A/customer B, tenant, session-only, expired-fact, deleted-fact, and SQLite-reopen cases. Assert out-of-scope records never reach the reranker and selection does not modify stored memory.
- [x] Build at most `candidate_limit` candidates from active facts and recent notes: rank term overlap first, break ties by recency and stable identity, and retain recent zero-overlap items if there is space. Feed only these candidates to the shared reranker. For an empty query, skip reranking and use existing behavior.
- [x] On success inject selected facts/notes through the existing fenced formatter and context budget. On failure retain the legacy facts/recent-notes block. Do not remove or hide records from memory export, audit, or Studio editing.
- [x] Test a relevant older memory wins against a newer irrelevant one within the candidate set; explicitly test that an older record outside the candidate window is not magically recovered.
- [x] Run `bundle exec rspec spec/insika/context/providers/memory_spec.rb spec/insika/memory_store_spec.rb spec/insika/agent_profile_spec.rb spec/insika/commands/memory_export_spec.rb spec/insika/load_guard_spec.rb`. Commit as `feat(memory): select relevant context on opt-in`.

## Task 3: Measure before rollout

**Files:** Add tracked cases under `evals/` following the existing corpus schema; update `docs/CONTEXT.md` and `docs/OBSERVABILITY.md`. Save measured results beside this plan as `2026-09-24-02-retrieval-results.md`, not in ignored `evals/baseline.json`.

- [x] Compare identical cases with reranking disabled/enabled: lexical ambiguity, older memory, paraphrase with no overlap, empty results, expired facts, tenant isolation, and provider failure. Record candidate recall, selected-context correctness, answer correctness, added p50/p95 latency, and reported/unknown cost.
- [x] Keep CI deterministic with stubbed results. A separately labeled provider experiment is required before claiming real answer-quality gains; never present stubbed scores as provider validation.
- [x] Enable only for an agent whose evals improve selected-context or answer correctness without regressing the other, with zero isolation/retention failures and measured latency/cost within that deployment's existing budget. If no budget is defined or no quality gain is observed, keep it opt-in and disabled in deployed packs.
- [x] Run `bundle exec rspec`; document config, external text transmission, fallback, cost, and candidate-recall limits. Commit as `test(retrieval): compare relevance and fallback behavior`.

## Conditional follow-ups

- **FTS5:** Only if candidate search latency becomes material. Implement the existing `fts5` selection using a tenant/agent-scoped index, transactional update/delete synchronization, rebuild, SQLite capability detection, and Scan fallback. It accelerates lexical retrieval; it does not solve synonym recall.
- **Embeddings:** Only if evals show relevant records missing from candidates because of wording. First evaluate bounded similarity search over vectors stored in SQLite; benchmark before adding a native extension. Specify model version/dimensions, reindexing, isolation, and deletion together.

**Done when:** An opt-in agent selects demonstrably better context, SQLite remains the store, and provider failure preserves a useful response.

## References

- [RubyLLM reranking](https://rubyllm.com/rerank/)
- [RubyLLM memory patterns](https://rubyllm.com/next/memory/)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)

## Execution result

Implemented on `codex/relevant-memory-knowledge`; all task and final reviews approved. Final verification: 5,715 examples, zero failures (seed 65387). [Measured fixture results](2026-09-24-02-retrieval-results.md) cover deterministic selection and fallback. Live-provider validation was not run; deployed packs remain disabled pending real quality, latency and cost evidence.
