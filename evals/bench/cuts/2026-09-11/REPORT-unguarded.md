# Cross-harness commerce bench

Generated 2026-09-11T22:53:28Z.

## Scorecard A — parity (same tools, same model, same prompt)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hermes | 9 | 5 | 56% | 7.4s | 17.7s | 6937 | $0.0007 | 4 store left wrong | — |
| insika | 9 | 9 | 100% | 6.5s | 8.7s | 1597 | $0.0002 | — | — |
| openclaw | 9 | 8 | 89% | 11.9s | 21.3s | 12088 | $0.0012 | 1 store left wrong | — |
| opencode | 9 | 6 | 67% | 8.0s | 10.7s | 3170 | $0.0003 | 3 store left wrong | — |
| pi | 9 | 7 | 78% | 6.2s | 7.4s | 2096 | $0.0002 | 2 store left wrong | — |

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hermes | 9 | 3 | 33% | 10.5s | 14.8s | 27007 | $0.0027 | 6 store left wrong | — |
| insika | 9 | 9 | 100% | 10.8s | 23.3s | 2054 | $0.0002 | — | — |
| openclaw | 9 | 8 | 89% | 16.8s | 22.9s | 75254 | $0.0075 | 1 store left wrong | — |
| opencode | 9 | 5 | 56% | 8.9s | 21.4s | 3987 | $0.0004 | 4 store left wrong | — |
| pi | 9 | 9 | 100% | 9.0s | 10.9s | 3015 | $0.0003 | — | — |

## The gap

A measures the harness; B measures the product. The distance between a harness's two rows is what its own layer adds — for us, that is the claim. If they come out the same, the engine's commerce layer does not pay for itself yet, and that is the finding.

| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |
| --- | --- | --- | --- | --- | --- |
| hermes | 5/9 (56%) | 3/9 (33%) | -22 | 6937 | 27007 |
| insika | 9/9 (100%) | 9/9 (100%) | 0 | 1597 | 2054 |
| openclaw | 8/9 (89%) | 8/9 (89%) | 0 | 12088 | 75254 |
| opencode | 6/9 (67%) | 5/9 (56%) | -11 | 3170 | 3987 |
| pi | 7/9 (78%) | 9/9 (100%) | +22 | 2096 | 3015 |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash.

Every cell traces to a run log under `runs-unguarded/`.
