---
title: Tools
parent: Build an agent
nav_order: 2
permalink: /tools/
---

# Tools

A **tool** is a function the model can call inside a turn. Insika has three
kinds, and the distinction that matters is **who can change one at runtime**:

| | **Code tool** | **Data tool** | **MCP tool** |
|---|---|---|---|
| What | a Ruby class (`< RubyLLM::Tool`) | an HTTP call described by config, no Ruby | an MCP server's tool, ingested |
| Lives | in the deployment image | as a row in SQLite | as data-tool rows in SQLite |
| Editable at runtime | no (shipped in the image) | **yes** (DSL / API / manifest / Studio) | **yes** (re-ingest) |
| Reach for it when | logic must run in-process (file edit, shell, subagent) | calling an external HTTP API | adopting a whole MCP toolset at once |

**MCP tools are not a separate runtime type.** An MCP ingestor discovers an MCP
server's tools and turns each into an HTTP **data tool** that posts a JSON-RPC
`tools/call`, tagged with a `group` naming the source instance. (Only
HTTP-transport MCP servers are ingestible; stdio is rejected.)

Code tools **win name collisions** — you cannot register a data tool whose name
shadows a code tool.

## Data tools: a tool is a row

A data tool is defined entirely by config — this is the operator-facing kind, and
the one you create and change without a rebuild. See
[`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/) for a runnable one.

```jsonc
{
  "name": "search_products",              // /\A[a-z][a-z0-9_]*\z/
  "description": "Search the catalog",     // required — this is what the model reads
  "parameters": { /* JSON Schema, safe subset */ },
  "request": {
    "method": "POST",                       // GET | HEAD | POST | PUT | PATCH | DELETE
    "url": "https://api.example.com/search",
    "headers": { "X-Session": "{{ctx.chat_id}}",
                 "Authorization": "Bearer {{secret.api_token}}" },
    "query": {}, "body": "…"
  },
  "response": { "extract": "json_path", "path": "$.results" },
  "secret_headers": ["Authorization"],
  "side_effect": true, "timeout": 30, "group": "catalog", "tags": []
}
```

**Placeholders** are resolved at turn time:

- `{{param}}` — a declared top-level parameter, filled from the model's call.
- `{{ctx.*}}` — turn context set **server-side, never by the model**: a closed set
  of `chat_id`, `store_id`, `agent_id`, `tenant`. This is how a tool knows *which*
  session/agent it is acting for without trusting the model.
- `{{secret.*}}` — allowed **only** inside a header named in `secret_headers`.
  A secret placeholder anywhere else is rejected (it would leak unmasked). The
  real secret value is injected at provision time and never lives on disk.

**Validation** happens on ingestion. Common rejections:

- `url` must be `http`/`https` — anything else is a 422.
- `parameters` is a **safe subset** of JSON Schema
  (`object/array/string/number/integer/boolean`); `oneOf`/`anyOf`/`allOf`/`$ref`/
  `if`/`then`/`else` are forbidden (not every provider supports them).
- `side_effect` defaults from the method (GET/HEAD → false, else true) and drives
  checkpoint/replay semantics (a completed side-effecting tool is not re-run on
  resume — see [Architecture](ARCHITECTURE.md#durability-checkpoints-and-resume)).

## Registering a tool

A tool appears in the Studio panel and enters an agent's tool-loop when it is
**registered** in the catalog **and** allowed by the agent's policy allowlist.
Four ways to write a data tool into the store — all **hot** (registry and catalog
reload, no restart):

1. **DSL** — `data_tool(name:, …)` in a `Insika.agent { … }` block.
2. **Studio** — the Tools panel editor.
3. **Manifest** — `POST /v1/tools/manifest`. Partial failure is isolated: one
   malformed tool becomes an `errors[]` entry; only a structural manifest error
   fails the whole request. The response reports `{ version, created, updated, errors }`.
4. **MCP ingestion** — import a server; each of its tools becomes a data tool.

### The one gotcha: env templating is manifest-only

`{{env.*}}` (and `{{secret.*}}`) are substituted **at ingestion, on the manifest
path**. Other write paths do **not** resolve `{{env.*}}` — a literal
`{{env.API_URL}}` there fails the `http`/`https` URL check and 422s. Rule:
**manifest tools may template the URL with `{{env.*}}`; tools written any other
way must ship a literal URL.** `{{ctx.*}}` and `{{param}}` work everywhere (they
resolve at turn time, not ingestion).

## Making it appear — and enter the tool-loop

1. **Panel visibility** = registered in the catalog. Data tools are marked
   editable; code tools are allow/deny only.
2. **Per-agent exposure** is set from the same panel, or by the agent's allowlist.
3. **Entering the tool-loop** is decided by the **policy allowlist**, not by tool
   type: deny wins, otherwise the agent sees `tools_allow ∪ tools_allow_groups`
   (or all, when both are absent). See [Agents](AGENTS.md#the-allowlist-convention).
4. **Deferred tools** (`tools_deferred`) are *not* offered directly — they appear
   as a short "available tools" list and the model must call `tool_search` to
   enable one. This is progressive disclosure for large toolsets — see
   [Context](CONTEXT.md).

## Egress: the SSRF guard (and its silent failure)

Data tools make outbound HTTP, so every call passes through the **EgressGuard**, a
Server-Side Request Forgery defense. The default posture is **strict: public
`https` only.** Three env vars widen it:

| Env | Effect |
|-----|--------|
| `INSIKA_EGRESS_HOSTS` | allowlist of hosts (CSV). The safe way to permit a specific backend. |
| `INSIKA_EGRESS_ALLOW_HTTP=1` | permit plain `http` — **loopback dev only** |
| `INSIKA_EGRESS_ALLOW_PRIVATE=1` | permit private/loopback IPs — **dev only** |

> ⚠️ **Egress failures are silent.** When a tool targets a blocked host (e.g. a
> plain-`http` localhost backend without the opt-ins), the guard turns the block
> into a `{ error: … }` returned **to the model** — the request never leaves the
> process, yet the stream still emits a tool call, so the model narrates a
> plausible failure and the conversation *looks* like it worked. You will not see
> an exception.
>
> **Always verify by the trace, never by the reply:** open the Studio session
> viewer — a healthy call shows the request, args, and the backend's `200`; a
> missing or errored call is almost always egress (host not in the allowlist, or
> `http`/private without the opt-in).

Egress is **orthogonal** to registration and allowlisting: a tool can be
registered, allowed, offered to the model, and still blocked at call time.

## Troubleshooting: "the tool is missing"

Work down this checklist:

1. **Registered?** Is it in the catalog (Studio Tools panel)? If not, the write
   or import failed — check the manifest `errors[]`.
2. **Allowed for this agent?** In `tools_allow` (or an allowed group), and not in
   `tools_deny`?
3. **Egress?** If it *appears and is called* but "fails", open the trace — a
   blocked call is ~99% egress.
4. **URL literal?** For non-manifest tools, an unresolved `{{env.*}}` would have
   422'd at import — re-check the definition.

## See also

- [Agents](AGENTS.md) — allowlists, groups, and per-agent tool exposure.
- [Plugins](PLUGINS.md) — where a code tool comes from, and how to package one.
- [Security](SECURITY.md) — egress, sandbox, and approval gating together.
- [Architecture](ARCHITECTURE.md) — the tool-loop and side-effect checkpointing.
- [`examples/data-tool/`](https://github.com/guizaols/insika/tree/main/examples/data-tool/) — a runnable data tool + the egress note.
