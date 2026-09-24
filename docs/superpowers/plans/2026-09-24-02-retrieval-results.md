# Retrieval evaluation: deterministic local fixture

Run: `PATH=/Users/guizaols/.local/share/mise/installs/ruby/4.0.6/bin:$PATH bundle exec ruby evals/retrieval/run.rb 30` on 2026-09-24. Thirty paired repetitions per case, in-memory store, real providers and Scan index, fake rerank interface, no network. The synthetic reply adapter reads only the first note/fact or knowledge description in the emitted context and is graded with the existing golden assertions. It tests selection plumbing, **not model answer quality**.

| Case | Candidate recall off → on | Context off → on | Synthetic answer off → on | Added p50 / p95 ms | Stub calls with unknown cost |
|---|---|---|---|---:|---:|
| deleted-concept | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | +0.000 / +0.006 | 0/30 |
| empty-results | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | +0.001 / +0.003 | 0/30 |
| expired-fact | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | +0.000 / +0.009 | 0/30 |
| lexical-ambiguity | 0/1 → 1/1 | fail → pass | fail → pass | +0.019 / +0.082 | 30/30 |
| older-memory | 1/1 → 1/1 | fail → pass | fail → pass | +0.025 / +0.072 | 30/30 |
| outside-note-window | 0/1 → 0/1 | fail → fail | fail → fail | +0.027 / +0.037 | 30/30 |
| paraphrase-no-overlap | 0/1 → 0/1 | fail → fail | fail → fail | +0.000 / +0.013 | 0/30 |
| provider-failure | 1/1 → 1/1 | pass → pass | pass → pass | +0.010 / +0.076 | 30/30 |
| tenant-isolation | 1/1 → 1/1 | pass → pass | pass → pass | +0.017 / +0.077 | 30/30 |

Candidate recall is derived from observed output: target presence among lexical top-K or legacy memory records when off, and among actual documents passed to the fake reranker when on. The known paraphrase and note-window misses are assertions in the spec, not hard-coded score branches; if a future index or window includes the target, recall becomes 1/1. Empty, expired and deleted cases have no valid target (N/A). Memory without reranking includes all active facts and ten recent notes, so its target may be present while an irrelevant note makes selected-context correctness fail. Context correctness requires target inclusion and distractor exclusion. These fixtures are not representative of production traffic.

Selected identities and candidate documents came from actual provider fragments and fake reranker calls. The answer adapter sees the emitted knowledge summary only; stored knowledge bodies are not read. Tenant isolation uses a distinct `PRIVATE_SCOPE_LEAK` marker and checks both reranker documents and emitted context, even if selection would hide a leaked candidate. Expired memory and deleted knowledge produced no forbidden context. A failed rerank emitted `provider_warning` and kept lexical context. All stubbed calls reported no usage; cost is unknown, with no numeric USD value. Local p50/p95 exclude network and real provider latency, and cannot be used as rollout budgets.

## Live provider experiment

Follow-up: a [live-model experiment with local agent packs](2026-09-24-02-retrieval-live-results.md) was subsequently completed. The status below describes this original deterministic run.

**NOT RUN.** No provider credential or deployment latency/cost budget was supplied. These synthetic results establish harness behavior only. Before enabling an agent, run the same corpus with that graph’s isolated provider credentials and a registered rerank model, compare real answers, and confirm selected-context or answer improvement without regression, zero isolation/retention failures, and latency/cost within its existing deployment budget. Deployed packs remain off.

## Observed candidate documents and selections

- `deleted-concept`: candidates []; off selected []; on selected []; isolation safe True; events [].
- `empty-results`: candidates []; off selected []; on selected []; isolation safe True; events [].
- `expired-fact`: candidates []; off selected []; on selected []; isolation safe True; events [].
- `lexical-ambiguity`: candidates ["cedar-sale\ncedar delivery sale\ncedar delivery sale", "cedar-delivery\ncedar arrives Tuesday\ndelivery detail"]; off selected ["cedar-sale"]; on selected ["cedar-delivery"]; isolation safe True; events ["retrieval_reranked"].
- `older-memory`: candidates ["older pickup Tuesday", "newer delivery Wednesday"]; off selected ["note:older", "note:newer"]; on selected ["note:older"]; isolation safe True; events ["retrieval_reranked"].
- `outside-note-window`: candidates ["new9 filler", "new8 filler", "new7 filler"]; off selected ["note:new0", "note:new1", "note:new2", "note:new3", "note:new4", "note:new5", "note:new6", "note:new7", "note:new8", "note:new9"]; on selected ["note:new9"]; isolation safe True; events ["retrieval_reranked"].
- `paraphrase-no-overlap`: candidates []; off selected []; on selected []; isolation safe True; events [].
- `provider-failure`: candidates ["cedar-delivery\ncedar arrives Tuesday\ndelivery detail"]; off selected ["cedar-delivery"]; on selected ["cedar-delivery"]; isolation safe True; events ["provider_warning"].
- `tenant-isolation`: candidates ["tenant-visible\ncedar arrives Tuesday\ndelivery detail"]; off selected ["tenant-visible"]; on selected ["tenant-visible"]; isolation safe True; events ["retrieval_reranked"].
