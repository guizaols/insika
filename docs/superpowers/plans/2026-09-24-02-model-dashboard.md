# Studio model dashboard

Approved scope: a Studio dashboard for model cost, tokens, durations (p50/p90/p95), volume, failures, retries, and slow calls linked to tasks.

## Global Constraints

- Reuse the existing store, native events, and Studio layout. No new dependencies or client-side charts.
- Persist content-free request summaries independently of the 200-event task trace. Never derive historical totals from that capped trace or fabricate a backfill.
- Preserve lazy RubyLLM loading and canonical billing counters. Recording failures must not interrupt execution or other diagnostics.
- Request latency includes native retries. Percentiles use exact nearest rank over measured completed requests; retries are usage attempts beyond the first, not Insika executions.
- Sum only reported costs; show unknown-cost coverage explicitly. Unknown values are never displayed as measured zero. Keep input/output/cache-read/cache-write/thinking token buckets separate.
- Historical summaries follow task lifetime: task deletion, retention, and tenant purge remove them, and late events cannot recreate deleted-task records. Store JSON uses string keys and an explicit content-free allowlist.
- Studio remains operator-authenticated. English UI/docs; no prompts, responses, credentials, or exception messages in summaries.

## Task 1: Durable request metrics

Create `ModelMetricsStore` over the existing KV backend, one summary per task/request. Consume `llm_request` and `llm_usage` directly in Executor with independent best-effort recording. Support usage before and after request completion, actual fallback provider/model, and concurrent task isolation. Retain counters rather than an unbounded attempt list. Completed requests with no usage still count toward requests/latency and have unknown cost. Incomplete usage-only records are excluded from reports until the request arrives.

Provide a report for a UTC rolling period (24 hours, 7 days, 30 days; default 7 days), optional exact provider/model filters, total and per-provider/model rows, and the 20 slowest measured requests. Include request/attempt/failure/retry counts, separate token buckets, known cost subtotal, unknown-cost request count, p50/p90/p95, filter options. State that history starts with deployment and task deletion removes history. Report through current store records without loading task trace tails. Use a `ponytail:` comment for any whole-scope scan with its ceiling/upgrade path.

Wire through core requires, Graph spine/result, Executor, TaskStore deletion, all three Studio boot paths, and optional Studio collaborator configuration. Add MemoryStore/SQLite specs for real persistence/reopen, >200 events, late usage, percentiles/filters/unknown values, cleanup/no-orphans, and an integration spec covering real native retry and fallback events where existing fixtures allow. Run focused specs. Commit implementation.

## Task 2: Studio page and docs

Add authenticated `GET /studio/models`, a Models navigation item in Operate, and an ERB view using existing cards, KPI strip, tables and native GET filters. Show period/provider/model filters; request volume, reported USD subtotal and unknown cost coverage, errors/retries, p50/p90/p95; per-model summary with separate token buckets; slowest 20 requests with safe task links. Empty/missing-store state must render safely. Explain request latency/retry semantics and retained history in concise page copy; show missing numbers as a dash. Escape provider/model/task values. No assets rebuild unless assets change.

Add route/render/auth/filter/escaping specs with known metric fixtures. Document the page and history limitations in observability docs. Run focused specs and the full suite once after implementation; stage new lib files and commit. Controller performs browser QA, task review and final review, then updates the already-authorized local server on 9293 preserving its database/environment.
