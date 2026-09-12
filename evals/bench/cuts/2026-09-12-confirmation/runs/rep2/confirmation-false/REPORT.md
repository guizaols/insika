# Cross-harness commerce bench

Generated 2026-09-12T20:45:28Z.

## Scorecard B — out of the box (each harness as it ships)

| Harness | Cells | Passed | Rate | Time p50 | Time p95 | Tokens/success | Cost/success | Failure classes | Not measured |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| insika | 7 | 3 | 43% | 26.2s | 39.3s | 6849 | — | 6 duplicate side effect · 5 store left wrong · 1 wrong tool behaviour · 1 invention | — |

## How to read the numbers

Time is wall clock measured by the runner around each turn, summed over the task — never self-reported. It includes the adapter's own process spawn, which every entrant pays, ours included; p50 is the honest column and p95 is where a harness that retries silently shows up.

Cost per success is blank for a harness that reports no token usage, and blank is the truth: an assumed zero would put the harness that measures nothing at the top of the column.


Every cell traces to a run log under `confirmation-false/`.
