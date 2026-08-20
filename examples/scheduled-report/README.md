# scheduled-report

The report pipeline in one file: a **recurring schedule** (the engine's own
tick fires it), a **`daily-digest` skill** (the inline-SVG pattern), the
**`save_artifact` tool** (the report destination), and the per-agent
**allowlist** that gates it.

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/scheduled-report/report_agent.rb
```

Runs one report turn right now (the same turn the schedule would fire at 22:00):
the agent builds a self-contained HTML digest, calls `save_artifact`, and prints
the returned URL. Open `/studio/artifacts/<id>` in the Studio to see it rendered
inside the sandboxed iframe.

To let the engine fire it on its own schedule and watch it land on the Artifacts
tab:

```bash
DEEPSEEK_API_KEY=sk-... ruby examples/scheduled-report/report_agent.rb --serve
```

Log in at `/studio` with the printed token and pick the `reporter` agent.

## What the file demonstrates

- **The allowlist is the switch.** `tools_allow %w[save_artifact]` is the ONLY
  thing that gives the model the `save_artifact` tool. Remove it and the turn
  cannot save — nothing global enables it.
- **The tenant is bound, never typed.** The artifact is stored under the
  agent's tenant (`platform` in a single-tenant install). No parameter the
  model types picks the tenant — a report from store A can never appear in, or
  be linked from, store B. This is the same rule a multi-tenant deployment
  applies to its data-defined tools (`{{ctx.command_tenant}}`).
- **Artifact content is untrusted.** The report is served with
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`
  and rendered in a sandboxed iframe. That is why the skill forbids
  `<script>`, external fonts and external fetches — the report is a page, and
  the page must be self-contained.
- **A report expires.** Set `artifact_ttl_days` in the deployment settings and
  the retention sweep removes old reports even if you keep conversations
  forever.

## Notes

- The `schedule` block is the recurring-turn half (see
  [`docs/SCHEDULING.md`](../../docs/SCHEDULING.md)); the `save_artifact` tool,
  the routes and the retention reach are the report destination (see
  [`docs/ARTIFACTS.md`](../../docs/ARTIFACTS.md)).
- There is no real store here. The skill's "numbers" are whatever the model
  can say about the (empty) day — the point is the pipeline, not the data. A
  real report wires a data-defined tool (or an MCP server) with a read-only
  credential, and this is where the tenant rule becomes concrete: the store is
  a `{{ctx.*}}` binding the Executor deposits, **never** a parameter the model
  types (see the `ctx.*` table in [`docs/TOOLS.md`](../../docs/TOOLS.md)).

  ```ruby
  data_tool(
    "name"        => "sales_by_day",
    "description" => "Daily sales totals for the last N days.",
    "parameters"  => {
      "type" => "object",
      "properties" => { "days" => { "type" => "integer", "description" => "how many days back" } },
      "required" => %w[days]
    },
    "request" => {
      "method" => "GET",
      # {{days}} is the model's argument; {{ctx.store_id}} is bound from the
      # turn — the model cannot point this tool at another store.
      "url" => "https://reports.internal.example/sales?days={{days}}&store={{ctx.store_id}}"
    },
    "response" => { "extract" => "body_raw" }
  )
  ```
