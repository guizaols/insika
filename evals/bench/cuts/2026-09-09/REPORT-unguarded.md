# Cross-harness commerce bench

Generated 2026-09-11T11:48:23Z.

## Scorecard A — parity (same tools, same model, same prompt)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-code | 9 | 8 | 89% | 7.2s | 9.4s | 11954 | $0.0012 | 1 store left wrong | — |
| hermes | 9 | 6 | 67% | 6.9s | 9.1s | 7039 | $0.0007 | 3 store left wrong | — |
| insika | 9 | 9 | 100% | 5.9s | 6.9s | 1647 | $0.0002 | — | — |
| openclaw | 9 | 8 | 89% | 12.8s | 21.6s | 12261 | $0.0012 | 1 store left wrong | — |
| opencode | 9 | 5 | 56% | 7.5s | 10.5s | 4245 | $0.0004 | 4 store left wrong | — |
| pi | 9 | 9 | 100% | 6.1s | 7.1s | 2058 | $0.0002 | — | — |

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude-code | 9 | 6 | 67% | 7.0s | 11.2s | 14994 | $0.0015 | 3 store left wrong | — |
| hermes | 9 | 4 | 44% | 9.6s | 11.2s | 26966 | $0.0027 | 5 store left wrong | — |
| insika | 9 | 9 | 100% | 5.1s | 8.0s | 1712 | $0.0002 | — | — |
| openclaw | 9 | 7 | 78% | 16.2s | 22.3s | 76442 | $0.0076 | 2 store left wrong | — |
| opencode | 9 | 4 | 44% | 6.5s | 9.4s | 611 | $0.0001 | 5 store left wrong | — |
| pi | 9 | 8 | 89% | 6.7s | 8.1s | 2991 | $0.0003 | 1 store left wrong | — |

## The gap

A measures the harness; B measures the product. The distance between a harness's two rows is what its own layer adds — for us, that is the claim. If they come out the same, the engine's commerce layer does not pay for itself yet, and that is the finding.

| Harness | A passed | B passed | Δ points | A tokens/success | B tokens/success |
| --- | --- | --- | --- | --- | --- |
| claude-code | 8/9 (89%) | 6/9 (67%) | -22 | 11954 | 14994 |
| hermes | 6/9 (67%) | 4/9 (44%) | -22 | 7039 | 26966 |
| insika | 9/9 (100%) | 9/9 (100%) | 0 | 1647 | 1712 |
| openclaw | 8/9 (89%) | 7/9 (78%) | -11 | 12261 | 76442 |
| opencode | 5/9 (56%) | 4/9 (44%) | -11 | 4245 | 611 |
| pi | 9/9 (100%) | 8/9 (89%) | -11 | 2058 | 2991 |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: $0.0886/M in, $0.1772/M out, blended here at 9:1.

Every cell traces to a run log under `runs-unguarded/`.
