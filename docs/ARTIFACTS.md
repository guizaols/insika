---
title: Artifacts
parent: Operate
nav_order: 3
permalink: /artifacts/
---

# Artifacts — a report the agent can hand you a URL to

A channel message is ephemeral, unformatted and capped. A scheduled report turn
(see [Schedules](SCHEDULING.md)) produces something no message can carry: a page
— tables, sections, inline charts. An **artifact** is that page as a thing that
exists afterwards: listable, linkable, and — because it carries customer PII —
deletable on the same terms as everything else the engine stores.

Deliberately small: a store, a tool, a route. Not a CMS.

## The `save_artifact` tool

A registry tool, allowlisted per agent like every tool — **the allowlist IS the
switch**:

```ruby
agent = Insika.agent("reporter") do
  instructions "…"
  tools_allow %w[save_artifact]   # without this, the tool is not even offered
end
```

The agent hands in `title` + `content` (default mime `text/html`; also
`text/markdown` and `image/svg+xml`) and gets the URL back, which it can include
in a channel message ("today's report: <url>"). When a signing key is
configured (below), the result also carries a `signed_url` that expires.

```jsonc
{ "id": "…", "url": "https://…/studio/artifacts/<id>/content",
  "signed_url": "https://…/studio/artifacts/s/<id>?exp=…&sig=…" }   // only with a key
```

The tenant binding is **inherited, never chosen**: an artifact belongs to the
tenant of the agent that saved it — a binding of the tool instance, never a
parameter the model types. Store A's report can never appear in, or be linked
from, store B.

## Serving

- `GET /studio/artifacts` — the Studio's per-agent list (the listing IS the
  history; no versioning — one report per run).
- `GET /studio/artifacts/:id` — the preview page, rendered **inside a sandboxed
  iframe** (no scripts, no same-origin, no forms).
- `GET /studio/artifacts/:id/content` — the raw page (authenticated).
- `GET /studio/artifacts/s/:id?exp=…&sig=…` — the **signed link**: the only
  artifact route that works without a Studio session. HMAC-SHA256 over
  `(id, expiry)` with `INSIKA_ARTIFACT_SIGNING_KEY`, verified in constant time.
  Expired or bad signatures **404 (never 403 — no oracle)**. Rotating the key
  invalidates every outstanding link — the documented behavior, not a bug.
  Without `INSIKA_ARTIFACT_SIGNING_KEY` there is no signed surface at all.

**Artifact content is untrusted.** It is LLM output. Both content routes send:

```http
Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:
X-Content-Type-Options: nosniff
```

No script, no external fetch, no forms. The model writes HTML with **inline
SVG** for charts — that is a skill instruction (palette, tables, pure-SVG bars),
not engine code. A "real" charting need is a plugin.

## Reasoning effort on a report turn

A report turn is not one shape of work — it plans, then it mines, then it
writes. `thinking` is one value per agent for the whole turn, so an agent set to
`high` pays deliberation on every one of the 30–50 tool calls a real report
makes, and that is where the 300 s turn timeout gets spent.

Split the phases across agents instead, which the engine already supports today:

```ruby
Insika.system do
  # The miners: one narrow question each, no judgement to make.
  agent("sales_miner") do
    model "deepseek-v4-flash"
    params thinking: "low"
    tools %w[query_sales]
    instructions "Answer ONE question about sales from the store data. Numbers, no prose."
  end

  # The orchestrator: it plans the report and writes it. This is the turn
  # that deserves the deliberation.
  agent("reporter") do
    model "deepseek-v4-flash"
    params thinking: "high"
    tools %w[save_artifact]
    subagents "sales_miner"
    instructions "Plan the report, call spawn_subagents ONCE for every number you need, then write the page and save_artifact it."
  end
end
```

Two things make this work: a child inherits the *environment* (model, thinking)
only as a **default**, so its own `params thinking:` wins; and `spawn_subagents`
runs the children in parallel, so wall-clock is the slowest miner rather than
the sum. Each child also mines in its own isolated context, which is what keeps
the orchestrator's context from filling with raw rows.

Measure it before reaching for anything cleverer: the numbers that matter are
the turn's wall-clock, the timeout rate, and the judge score on the same report.
Per-phase effort *inside* a single turn is a real idea, but it is only worth
building once this recipe is shown not to be enough.

## Limits and retention

- **Size cap** — `INSIKA_ARTIFACT_MAX_BYTES` (default 1 MB): an artifact is a
  page, not an attachment. The mime allowlist is `text/html`, `text/markdown`,
  `image/svg+xml`; no binaries, no uploads.
- **Expiry** — the settings key `artifact_ttl_days` (Integer days; absent = OFF)
  ages artifacts out on the retention sweep's own daily pass, **independent of
  `retention_days`**: a deployment that keeps its conversations forever must
  still expire the reports. This is the guarantee that PII inside a report
  expires — the honest reach, because no reader can see inside the opaque HTML.

## Privacy

- `delete_tenant_data` deletes the tenant's artifacts (the tenant binding is
  the isolation boundary).
- `forget_customer` **cannot** know which artifacts mention a customer (content
  is opaque HTML), so per-customer redaction inside a report is not pretended to
  exist; the `artifact_ttl_days` knob is the guarantee that a report's PII
  expires.

## See also

- [Schedules](SCHEDULING.md) — the recurring turns whose output lands here.
- [Tools](TOOLS.md) — how a tool enters the per-agent allowlist.
- [`examples/scheduled-report/`](https://github.com/guizaols/insika/tree/main/examples/scheduled-report/)
  — schedule + skill + data tool + artifact, tenant-bound, end to end.
