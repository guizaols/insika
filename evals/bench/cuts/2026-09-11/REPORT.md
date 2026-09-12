# Cross-harness commerce bench

Generated 2026-09-12T00:33:40Z.

## Scorecard A — parity (same tools, same model, same prompt)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hermes | 36 | 33 | 92% | 7.9s | 24.8s | 11375 | $0.0011 | 2 store left wrong · 1 invention | — |
| insika | 36 | 35 | 97% | 11.6s | 18.6s | 2349 | $0.0002 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| openclaw | 36 | 36 | 100% | 13.7s | 27.3s | 15919 | $0.0016 | — | — |
| opencode | 36 | 33 | 92% | 7.9s | 26.0s | 1194 | $0.0001 | 3 wrong tool behaviour · 3 duplicate side effect · 3 store left wrong | — |
| pi | 36 | 34 | 94% | 8.7s | 23.9s | 2820 | $0.0003 | 3 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong · 1 invention | — |

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hermes | 36 | 34 | 94% | 12.1s | 35.6s | 42974 | $0.0043 | 1 invention · 1 store left wrong | — |
| insika | 36 | 36 | 100% | 8.7s | 29.7s | 2890 | $0.0003 | — | — |
| openclaw | 36 | 35 | 97% | 12.5s | 30.6s | 103351 | $0.0103 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| opencode | 36 | 35 | 97% | 9.6s | 27.2s | 1449 | $0.0001 | 1 invention | — |
| pi | 36 | 32 | 89% | 7.3s | 19.4s | 3929 | $0.0004 | 3 wrong tool behaviour · 3 duplicate side effect · 3 store left wrong · 1 more than one question | — |

## The gap

A measures the harness; B measures the product. The distance between a harness's two rows is what its own layer adds — for us, that is the claim. If they come out the same, the engine's commerce layer does not pay for itself yet, and that is the finding.

| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |
| --- | --- | --- | --- | --- | --- |
| hermes | 33/36 (92%) | 34/36 (94%) | +3 | 11375 | 42974 |
| insika | 35/36 (97%) | 36/36 (100%) | +3 | 2349 | 2890 |
| openclaw | 36/36 (100%) | 35/36 (97%) | -3 | 15919 | 103351 |
| opencode | 33/36 (92%) | 35/36 (97%) | +6 | 1194 | 1449 |
| pi | 34/36 (94%) | 32/36 (89%) | -6 | 2820 | 3929 |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: $0.0886/M in, $0.1772/M out, blended here at 9:1.

Every cell traces to a run log under `runs/`.
