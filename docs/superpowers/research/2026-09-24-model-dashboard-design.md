---
title: Model dashboard design research
nav_exclude: true
---

# Model dashboard design research

Reviewed official sources on 2026-09-24, before interface changes. Recommendations below are design judgments for Insika, not claims that these products use the exact proposed layout.

## References and useful findings

- [Langfuse: Chart any table](https://langfuse.com/docs/observability/features/events-table-charts) keeps charts and tables on the same filters and time range. Its chart controls separate metric, aggregation, and breakdown: counts, latency percentiles, cost sums, and model series. It uses temporal charts for trends and ranked horizontal charts for categorical comparison. Apply this distinction: requests and cost over time, p50/p90/p95 latency over time, and an exact-value model comparison below. Langfuse documents p50/p95/p99; p90 here is an Insika requirement.
- [Datadog: LLM cost monitoring](https://docs.datadoghq.com/llm_observability/investigate/cost/) combines total cost and token summaries with provider/model breakdowns. Its estimates derive from token counts and provider rates, and it distinguishes partial cost from unavailable cost. Apply the same honesty: label reported USD, expose coverage when known, and show unavailable rather than zero when pricing or usage is missing.
- [Carbon: Axes and labels](https://carbondesignsystem.com/data-visualization/axes-and-labels/) recommends clear labels, zero baselines for bar/area comparisons, consistent time increments, localized time labels, and visible gaps instead of interpolation across unavailable data. Apply these rules to every panel; sparse traffic must not compress time or imply measurements that never existed.
- [W3C WAI: Complex images](https://www.w3.org/WAI/tutorials/images/complex/) recommends a short chart description plus a detailed text alternative conveying its values, scales, relationships, and trends. An adjacent semantic table is a documented option. Apply this with an accessible chart name and a native expandable data table; a hover tooltip alone is insufficient.

## Recommended visual design

Use a restrained analytics page: a clear page title and shared range control; a compact summary row; a spacious two-column chart grid; and one model comparison table. Keep the existing Studio typography and navigation. Use subtle borders, neutral surfaces, generous panel padding, and a small consistent color palette. Give chart titles and primary values stronger weight than metadata. Avoid decorative gauges and miniature charts that cannot be read.

| Panel | Display | Meaning |
| --- | --- | --- |
| Requests over time | Vertical bars with a zero baseline | Actual call count per labeled time bucket |
| Reported cost over time | Line or lightly filled area | Sum of known USD cost per bucket; disclose missing pricing |
| Latency over time | Three lines, labeled p50/p90/p95 | Per-bucket percentiles from actual duration samples, in ms or seconds |
| Models | Table with proportional horizontal request bars | Model/provider, calls, known cost, tokens, p50/p90/p95; exact numbers remain visible |

Use the same time buckets and range across temporal panels. Keep costs and latency on separate axes/panels because their units differ. Give percentile lines both labels and distinguishable strokes, with an explicit legend. Keep model colors stable between displays where models are shown as series. Stack panels on narrow screens; preserve readable chart height and labels.

## Data and interaction requirements

- Draw real points with readable axis ticks, units, and bucket timestamps. Tooltips may add detail; the table must also expose values through keyboard and assistive technology.
- Represent a known bucket with no calls as zero requests. Represent missing latency/cost as unavailable, leaving a line gap. Do not substitute a zero duration, carry a previous value, or invent a trend.
- Use a visible point for a single measured bucket. When the entire range is empty, show “No model calls in this period” and a range-change action, without fake sample data.
- Distinguish “No calls,” “Latency unavailable,” “Cost unavailable,” and “Partial cost.” Never turn incomplete observations into an apparently complete total.
- Compute aggregate percentiles from the underlying duration samples, not an average of bucket percentiles. State what is timed; do not label whole-call latency as time to first token.

The existing aggregation and chart facilities should be reused where possible. This design needs readable real charts and truthful states, not a dashboard builder or a new charting dependency.
