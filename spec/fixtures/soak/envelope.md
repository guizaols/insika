# SOAK — fixture envelope

Synthesized envelope for the report specs. Calibrated, 72h, tiny scale
(4 turns/hour) so a fixture stays ~360 lines.

```yaml
version: 1
target: staging
target_url_host: staging.example
agent: soak-fixture
tenant: soak

duration_hours: 72
warmup_hours: 6

arrival: poisson
turns_per_hour: 4
session_turns: 2
concurrency_cap: 2
request_timeout_s: 120
corpus: spec/fixtures/soak/corpus.txt

web_concurrency: 1
chat_rate_limit: 0
agent_token_ceiling: 0
turn_timing: required

rss_growth_ratio: 1.15
prep_p95_drift_ratio: 1.50
restarts_max: 0
error_rate_ceiling: 0.005
no_usage_rate_ceiling: 0.002
coverage_min_ratio: 0.95
gap_seconds_max: 900
hourly_turn_floor: 2

rss_ceiling_mb: 900
prep_p95_ceiling_ms: 10
total_p95_ceiling_ms: 30_000

report_only:
  - ttft_p95_ms
  - total_p95_hourly
  - rss_slope_mb_per_day
  - heap_growth_ratio
  - db_growth_mb
  - cost_usd
  - tokens_per_turn
```
