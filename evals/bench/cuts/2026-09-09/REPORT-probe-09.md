# Cross-harness commerce bench

Generated 2026-09-11T11:48:22Z.

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| hermes | 10 | 10 | 100% | 27.7s | 35.4s | 59097 | $0.0059 | — | — |
| pi | 10 | 5 | 50% | 23.7s | 29.9s | 5964 | $0.0006 | 5 wrong tool behaviour · 5 duplicate side effect · 5 store left wrong | — |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.
Price: 0.1 USD per million tokens — deepseek/deepseek-v4-flash on OpenRouter, read 2026-09-09.

Every cell traces to a run log under `runs-probe-09/`.
