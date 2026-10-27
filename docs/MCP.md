---
title: MCP server
parent: Improve
nav_order: 7
permalink: /mcp/
---

# MCP server

Insika serves a read-only [Model Context Protocol](https://modelcontextprotocol.io)
server at `POST /mcp`. Point Claude Code, Cursor, Claude Desktop or the MCP Inspector at
it and ask about the conversations your agents ran: how much real traffic each
agent had, what a conversation said, and which guardrail flags fired and why.

It's the same data Studio shows, but you can query across sessions. You don't need a
shell on the host or any SQL.

## Connect

The endpoint uses the gateway bearer (`INSIKA_GATEWAY_TOKEN`) like `/v1`. It's an
operator surface: in `multi_tenant` mode a tenant credential gets `403`.

Claude Code:

```bash
claude mcp add --transport http insika https://your-insika.example.com/mcp \
  --header "Authorization: Bearer $INSIKA_GATEWAY_TOKEN"
```

Any client that reads the common `mcpServers` format:

```json
{
  "mcpServers": {
    "insika": {
      "type": "http",
      "url": "https://your-insika.example.com/mcp",
      "headers": { "Authorization": "Bearer ${INSIKA_GATEWAY_TOKEN}" }
    }
  }
}
```

To try it without a client:

```bash
npx @modelcontextprotocol/inspector
# Transport: Streamable HTTP · URL: http://localhost:9292/mcp · header Authorization: Bearer …
```

## Tools

There are five tools, and every one is read-only (`readOnlyHint: true`). Results come back both as JSON text
and as `structuredContent`. A list is wrapped as `{ "items": [...] }`.

| Tool | What it answers | Arguments |
|------|-----------------|-----------|
| `agent_summary` | Per agent: sessions, sessions with turns, turns by status, flagged sessions, first and last turn. | `since`, `include_synthetic` |
| `list_sessions` | Sessions newest first, with agent, customer, message and turn counts and open flags. | `agent`, `since`, `with_turns`, `flagged`, `include_synthetic`, `limit` (1–500, default 50) |
| `get_transcript` | One session's messages, each with role, origin and guardrail flags. | `session_id` (required), `max_chars` (per message, default 4000) |
| `list_flags` | One row per guardrail flag: category, source, reason, the message it judged and the reply that followed. | `agent`, `category`, `include_resolved`, `include_synthetic`, `limit` (1–500, default 100) |
| `turn_metrics` | Cost and tokens per model and operation, turn latency percentiles (time to first token, total, tools), calls and failures per tool, and failed turns by stage. These are the numbers on the Studio metrics page. | `agent`, `period` (`24h`, `7d`, `30d`), or `from` + `to` (ISO-8601) |

A good order is `agent_summary`, then `list_sessions` or `list_flags`, then
`get_transcript` for the sessions that matter. Use `turn_metrics` for how fast and
how expensive an agent is and which of its tools fail.

`turn_metrics` is listed only when the server has a model-metrics store. The
bundled `config.ru` and `Insika::Server::RackApp` pass one. If you build
`Server::App` yourself, pass `model_metrics_store:`.

### What counts as real traffic

- **With turns.** A session counts when the engine ran at least one turn in it. An
  imported transcript (see [migrate_openclaw](https://github.com/guizaols/insika/blob/main/scripts/migrate_openclaw.rb))
  has messages but no turns, so it tells you nothing about this engine.
  `list_sessions` returns only sessions with turns by default. Pass `with_turns: false` to see
  imported sessions, or `null` to see both.
- **Not synthetic.** Simulator (`sim-…`) and eval (`eval-…`) sessions are left out
  unless you pass `include_synthetic: true`.
- **Open flags.** `list_flags` returns flags nobody resolved. Pass `include_resolved: true` for
  all of them. In Studio, resolve a flag on the session page after you've judged it.

## Protocol

- Streamable HTTP transport. Each POST carries one JSON-RPC message and gets one JSON
  reply. A notification gets `202` with no body. `GET` and `DELETE` return `405`,
  because the server never pushes messages and keeps no MCP session.
- Protocol versions `2025-06-18` (preferred), `2025-03-26` and `2024-11-05`. On
  `initialize` the server answers with the client's version if it supports it, and
  with `2025-06-18` otherwise.
- Methods: `initialize`, `ping`, `tools/list`, `tools/call`. The tool list is fixed
  (`listChanged: false`).
- Errors follow JSON-RPC: `-32700` malformed JSON, `-32600` not a message object
  (batches included), `-32601` unknown method, `-32602` unknown tool or bad arguments.
  A session that doesn't exist is a tool result with `isError: true`, so the model
  can read it and correct itself.

## Privacy

Transcripts contain what customers wrote, including names and phone numbers when
the integration sends them. Anyone with this token can read every conversation, so
treat it like database access. Don't paste the token into a shared client config.

## Limits

Each session tool reads all session stats and all tasks in one pass
(`turn_metrics` reads only the rows in its time window). That's fine for thousands
of sessions on one SQLite file. Past that, a call gets slower in proportion to the
total, not to what it returns.

## Code

- [`lib/insika/session_insights.rb`](https://github.com/guizaols/insika/blob/main/lib/insika/session_insights.rb):
  the queries.
- [`lib/insika/server/mcp.rb`](https://github.com/guizaols/insika/blob/main/lib/insika/server/mcp.rb):
  the JSON-RPC transport.
