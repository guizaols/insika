# Cross-harness commerce bench

Generated 2026-09-10T01:15:45Z.

## Scorecard A — parity (same tools, same model, same prompt)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| insika | 36 | 36 | 100% | 6.0s | 15.4s | 2163 | $0.0002 | — | — |

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| insika | 36 | 32 | 89% | 11.4s | 23.3s | 2354 | $0.0002 | 2 duplicate side effect · 2 more than one question · 1 wrong tool behaviour · 1 store left wrong | — |

## The gap

A measures the harness; B measures the product. The distance between a harness's two rows is what its own layer adds — for us, that is the claim. If they come out the same, the engine's commerce layer does not pay for itself yet, and that is the finding.

| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |
| --- | --- | --- | --- | --- | --- |
| insika | 36/36 (100%) | 32/36 (89%) | -11 | 2163 | 2354 |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash.

Every cell traces to a run log under `runs-reasoning-off/`.
