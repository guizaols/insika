# Retrieval evaluation: deterministic local fixture

Run: `PATH=/Users/guizaols/.local/share/mise/installs/ruby/4.0.6/bin:$PATH bundle exec ruby evals/retrieval/run.rb 30` on 2026-09-24. Thirty paired repetitions per case, in-memory store, real providers and Scan index, fake rerank interface, no network. The synthetic reply adapter reads the first selected memory record or selected knowledge body and is graded with the existing golden assertions. It tests selection plumbing, **not model answer quality**.

| Case | Candidate recall off → on | Context off → on | Synthetic answer off → on | Added p50 / p95 ms | Stub calls with unknown cost |
|---|---|---|---|---:|---:|
| deleted-concept | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | -0.003 / +0.137 | 0/30 |
| empty-results | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | +0.009 / +0.559 | 0/30 |
| expired-fact | N/A (no relevant record) → N/A (no relevant record) | pass → pass | pass → pass | -0.002 / +0.497 | 0/30 |
| lexical-ambiguity | 0/1 → 1/1 | fail → pass | fail → pass | +0.015 / +0.196 | 30/30 |
| older-memory | 1/1 → 1/1 | fail → pass | fail → pass | +0.027 / +0.089 | 30/30 |
| outside-note-window | 0/1 (outside candidate window) → 0/1 (outside candidate window) | fail → fail | fail → fail | +0.027 / +0.036 | 30/30 |
| paraphrase-no-overlap | 0/1 (no lexical candidate) → 0/1 (no lexical candidate) | fail → fail | fail → fail | +0.000 / +0.080 | 0/30 |
| provider-failure | 1/1 → 1/1 | pass → pass | pass → pass | +0.012 / +0.240 | 30/30 |
| tenant-isolation | 1/1 → 1/1 | pass → pass | pass → pass | +0.014 / +0.091 | 30/30 |

Candidate recall is target presence among lexical top-K or legacy memory records when off, and among actual documents passed to the fake reranker when on. Empty, expired and deleted cases have no valid target (N/A). The paraphrase never reaches the lexical candidate set; the oldest note is outside the recent read window. Memory without reranking includes all active facts and ten recent notes, so its target may be present while an irrelevant note makes selected-context correctness fail. Context correctness requires target inclusion and distractor exclusion. These fixtures are not representative of production traffic.

Selected identities and candidate documents came from actual provider fragments and fake reranker calls. Knowledge tenant isolation, expired memory and deleted knowledge produced no forbidden context. A failed rerank emitted `provider_warning` and kept lexical context. All stubbed calls reported no usage; cost is unknown, with no numeric USD value. Local p50/p95 exclude network and real provider latency, and cannot be used as rollout budgets.

## Live provider experiment

**NOT RUN.** No provider credential or deployment latency/cost budget was supplied. These synthetic results establish harness behavior only. Before enabling an agent, run the same corpus with that graph’s isolated provider credentials and a registered rerank model, compare real answers, and confirm selected-context or answer improvement without regression, zero isolation/retention failures, and latency/cost within its existing deployment budget. Deployed packs remain off.

## Observed candidate documents and selections

- `deleted-concept`: candidates []; off selected []; on selected []; events [].
- `empty-results`: candidates []; off selected []; on selected []; events [].
- `expired-fact`: candidates []; off selected []; on selected []; events [].
- `lexical-ambiguity`: candidates ["cedar-sale\ncedar delivery sale\ncedar delivery sale", "cedar-delivery\ncedar delivery window\ncedar arrives Tuesday"]; off selected ["cedar-sale"]; on selected ["cedar-delivery"]; events ["retrieval_reranked"].
- `older-memory`: candidates ["older pickup Tuesday", "newer delivery Wednesday"]; off selected ["note:older", "note:newer"]; on selected ["note:older"]; events ["retrieval_reranked"].
- `outside-note-window`: candidates ["new9 filler", "new8 filler", "new7 filler"]; off selected ["note:new0", "note:new1", "note:new2", "note:new3", "note:new4", "note:new5", "note:new6", "note:new7", "note:new8", "note:new9"]; on selected ["note:new9"]; events ["retrieval_reranked"].
- `paraphrase-no-overlap`: candidates []; off selected []; on selected []; events [].
- `provider-failure`: candidates ["cedar-delivery\ncedar delivery\ncedar arrives Tuesday"]; off selected ["cedar-delivery"]; on selected ["cedar-delivery"]; events ["provider_warning"].
- `tenant-isolation`: candidates ["tenant-visible\ncedar delivery\ncedar arrives Tuesday"]; off selected ["tenant-visible"]; on selected ["tenant-visible"]; events ["retrieval_reranked"].
