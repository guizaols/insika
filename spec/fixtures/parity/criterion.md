# Criterion — a frozen shadow-parity rule (spec fixture)

> The real criterion is the deployment's own: the engine reads the file
> `INSIKA_PARITY_CRITERION` points at, and records its SHA-256 with every pair.
> This fixture exists so the Studio parity page and the fold have a stable,
> public file to work against in the suite.

```yaml
version: 1
unit: exchange
window_days: 7
pairs_per_day: 30
min_decided: 200

min_judge_models: 3
both_orders: true

estimator: wilson_lower_95
win_or_tie_floor: 0.80

worse_rate_ceiling: 0.10
undecided_rate_ceiling: 0.20
incomplete_rate_ceiling: 0.20

per_agent_min_decided: 50
per_agent_win_or_tie_floor: 0.70

human_assisted: report_only
silent: report_only
```