# Cross-harness commerce bench

Generated 2026-09-10T10:48:01Z.

## Scorecard A — parity (same tools, same model, same prompt)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-code | 36 | 34 | 94% | 8.1s | 18.0s | 12887 | $0.0013 | 2 wrong tool behaviour · 2 duplicate side effect · 2 store left wrong | — |
| hermes | 36 | 35 | 97% | 8.5s | 24.0s | 10964 | $0.0011 | 1 store left wrong | — |
| insika | 36 | 34 | 94% | 10.0s | 27.3s | 2170 | $0.0002 | 1 more than one question · 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| openclaw | 36 | 35 | 97% | 14.3s | 30.6s | 14122 | $0.0014 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| opencode | 36 | 31 | 86% | 8.8s | 21.0s | 2973 | $0.0003 | 5 store left wrong · 2 duplicate side effect · 1 wrong tool behaviour · 1 reply missed the point | — |
| pi | 36 | 36 | 100% | 6.2s | 14.2s | 2619 | $0.0003 | — | — |

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-code | 36 | 34 | 94% | 7.4s | 19.7s | 13237 | $0.0013 | 2 store left wrong · 1 wrong tool behaviour · 1 duplicate side effect | — |
| hermes | 36 | 32 | 89% | 20.7s | 46.1s | 45256 | $0.0045 | 4 no answer from the harness | — |
| insika | 36 | 34 | 94% | 11.8s | 31.5s | 2263 | $0.0002 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong · 1 invention | — |
| openclaw | 36 | 35 | 97% | 23.1s | 37.4s | 102196 | $0.0102 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| opencode | 36 | 35 | 97% | 6.8s | 16.5s | 2462 | $0.0002 | 1 wrong tool behaviour · 1 duplicate side effect · 1 store left wrong | — |
| pi | 36 | 34 | 94% | 7.5s | 14.6s | 3717 | $0.0004 | 1 duplicate side effect · 1 no answer from the harness | — |

## The gap

A measures the harness; B measures the product. The distance between a harness's two rows is what its own layer adds — for us, that is the claim. If they come out the same, the engine's commerce layer does not pay for itself yet, and that is the finding.

| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |
| --- | --- | --- | --- | --- | --- |
| claude-code | 34/36 (94%) | 34/36 (94%) | 0 | 12887 | 13237 |
| hermes | 35/36 (97%) | 32/36 (89%) | -8 | 10964 | 45256 |
| insika | 34/36 (94%) | 34/36 (94%) | 0 | 2170 | 2263 |
| openclaw | 35/36 (97%) | 35/36 (97%) | 0 | 14122 | 102196 |
| opencode | 31/36 (86%) | 35/36 (97%) | +11 | 2973 | 2462 |
| pi | 36/36 (100%) | 34/36 (94%) | -6 | 2619 | 3717 |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: $0.0886/M in, $0.1772/M out, blended here at 9:1.

Every cell traces to a run log under `runs/`.
