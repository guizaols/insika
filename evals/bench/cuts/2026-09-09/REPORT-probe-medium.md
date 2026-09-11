# Cross-harness commerce bench

Generated 2026-09-11T11:48:22Z.

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| insika | 30 | 24 | 80% | 18.6s | 29.8s | 2965 | $0.0003 | 6 wrong tool behaviour · 6 invention · 3 duplicate side effect · 3 store left wrong | — |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09: $0.0886/M in, $0.1772/M out, blended here at 9:1.

Every cell traces to a run log under `runs-probe-medium/`.
