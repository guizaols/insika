# Retrieval evaluation: live models with local agent packs

Run date: 2026-09-24. Runtime commit: `8059cc5a`. Follow-up to the [deterministic evaluation](2026-09-24-02-retrieval-results.md).

**Finding:** the enabled configuration recovered an older customer preference in all six live trials, versus none without it. Knowledge selection improved, but its usefulness to these agents remains unproven. Keep deployment activation pending a representative corpus and an agreed budget.

## Method

The local Natura, VAIO and Cacau Show packs ran through the real Executor using the existing `Evals::Runner` and `GraphTransport`. Chat used `deepseek-v4-flash`; reranking used OpenRouter's `cohere/rerank-v3.5`. Credentials came from the local environment files into each graph's configuration. No response or rerank result was stubbed.

Each agent received three controlled cases, twice with retrieval reranking disabled and twice enabled: 36 turns, 18 paired comparisons. The first repetition ran off/on, the second on/off. Each turn started with a fresh SQLite database, the same pack and the same seeded records. This measured model calls through the in-process graph, not deployed HTTP transport or TTFB.

These are **real packs and models with synthetic records**, not a replay of production conversations. The inspected local databases had almost no customer memory and no learned knowledge suitable for this comparison. Both configurations enabled memory and knowledge retrieval in the test profile. Commercial tools were removed for this retrieval-only experiment; built-in local memory tools remained available. Prompts and skills were retained. Knowledge extraction was disabled. The enabled profile used `top_k: 1`, `candidate_limit: 20`, and a two-second rerank timeout.

## Observations

Counts below are out of two trials per cell. “Target recalled” means the response actually stated the expected value from the selected context, not merely mentioned that word among possible options. It is not a general business-quality score.

| Agent | Case | Target in context, off → on | Target recalled, off → on |
|---|---|---:|---:|
| Natura | Older customer preference | 0 → 2 | 0 → 2 |
| VAIO | Older customer preference | 0 → 2 | 0 → 2 |
| Cacau Show | Older customer preference | 0 → 2 | 0 → 2 |
| Natura | Knowledge with lexical distractor | 0 → 2 | 0 → 0 |
| VAIO | Knowledge with lexical distractor | 0 → 2 | 0 → 0 |
| Cacau Show | Knowledge with lexical distractor | 0 → 2 | 0 → 1 |
| Natura | Paraphrase without overlap | 0 → 0 | 0 → 0 |
| VAIO | Paraphrase without overlap | 0 → 0 | 0 → 0 |
| Cacau Show | Paraphrase without overlap | 0 → 0 | 0 → 0 |

The memory targets were lavender, silver and dark chocolate, respectively. Each note was followed by twelve unrelated notes. The legacy ten-note window excluded it; the enabled twenty-candidate window included it. **This gain combines a wider candidate window and reranking. It does not establish that a model is better than a wider lexical window.**

The knowledge fixture paired an exact-word distractor with a useful summary about fictional “Aurora” packaging. Reranking selected the useful summary in all six attempts. Most replies still required an official catalog source or rejected the item as outside their domain. Cacau Show once repeated the FSC detail with an explicit uncertainty caveat. Because Aurora is not a verified product in these packs, refusing to assert its material is reasonable: this fixture demonstrates selection, but cannot establish a production answer-quality gain or regression.

The paraphrase fixture used “caixa” in the question and “invólucro” in the stored record. Neither configuration found a candidate. The question also omitted the item name, so clarification was reasonable. These results confirm the candidate-search limitation, not a failure of conversational judgment.

All 36 turns completed. Other-scope and expired-record markers were absent from captured context and candidate documents; the output checks also passed. All 12 attempted reranks succeeded, with no timeout or fallback. This is a small controlled isolation/retention check, not a comprehensive security assessment.

## Latency and reported cost

| Measurement | Disabled | Enabled |
|---|---:|---:|
| Turns | 18 | 18 |
| End-to-end p50 | 1,949 ms | 2,043 ms |
| End-to-end p95 | 3,608 ms | 4,973 ms |
| Reported chat cost | $0.009178 | $0.003521 |
| Reported rerank cost | $0 | $0.012000 |
| Reported total cost | $0.009178 | $0.015521 |

Paired enabled-minus-disabled latency: p50 **+267 ms**, p95 **+1,979 ms**. The 12 individual rerank operations measured p50 **338 ms**, p95 **1,436 ms**. Percentiles use nearest rank; with this sample size the rerank p95 is the observed maximum, not a stable production estimate.

Native diagnostics recorded 48 successful chat requests and 12 successful rerank requests across the 36 turns. Every measured request had a reported cost. Reranking reported **$0.001 per request** but no token counts; token usage remains unknown and must not be invented for token-based spend enforcement. Reported cost is not a reconciled provider invoice.

The measured batch reported **$0.024699** total, excluding the separate connectivity probe and two-turn pilot. Chat cost varied with cache hits, response length and local memory-tool calls. Although order was reversed in repetition two, the sample does not isolate a causal chat-cost reduction. The enabled configuration cost more overall in this batch. No deployment budget was supplied, so budget acceptance remains undecided.

## Grading and limits

All 36 final replies were inspected. Simple `reply_includes` checks produced three false positives: two Cacau Show replies listed “amargo” among possible preferences and one VAIO reply listed “prata”, while explicitly saying the stored preference was unknown. These were corrected in the reviewed results and counted as no recall. Raw keyword verdicts were retained separately.

One disabled Natura reply exposed English narration about skill selection; another disabled VAIO reply was in English. These are observed response-quality issues in the tested packs, outside the retrieval correctness checks. They were not repaired or hidden by this experiment.

The next useful comparison is the agents' own in-domain learned records and representative questions, with their normal read-only tool flow, plus a wider lexical-window baseline. Until then, the evidence supports a bounded memory-retrieval pilot, not general activation of learned knowledge or a claim of overall agent improvement.

## Local reproduction and evidence

The experiment script and raw records are local, gitignored working material under `tmp/retrieval-live/`; they are not shipped with the gem. From this worktree, with the configured local environment files:

```sh
export PATH=/Users/guizaols/.local/share/mise/installs/ruby/4.0.6/bin:$PATH
EVAL_RUN=another-unique-run bundle exec ruby tmp/retrieval-live/run.rb
```

The script refuses to reuse a database. The measured batch is `tmp/retrieval-live/measured/results.json`; manually reviewed verdicts and reasons are `reviewed-results.json` in the same directory. Each record contains the question, response, selected context, candidate list, native usage/cost events and timing. Databases were created solely for this run.

Pack SHA-256 fingerprints (the JSON serialization of the original pack, before test overrides):

| Pack | SHA-256 |
|---|---|
| `agent-store-natura` | `9f82c2d461e3636979a9376ac8f707be0a0e059710b2f1800ca35b39d0fc8308` |
| `agent-store-vaio` | `e8f9de46052de13a1a9dada5bc36f57cb419e59bcf6652d9d38a787739662513` |
| `agent-store-cacau-show` | `35d46198e5b690b4e56ee8862f781e9791fc5c75973afde111431ef96c9b2fd7` |
