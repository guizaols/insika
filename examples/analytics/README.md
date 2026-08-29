# analytics

An MCP tool-loop over **http**, wired to a real analytics server that needs
auth: [OpenSEO](https://github.com/every-app/open-seo), an open-source
alternative to Semrush/Ahrefs. `repo-explorer` and `browser-agent` show MCP
against keyless, public servers; this one shows the other half — a server
that's account-scoped, so every tool call carries a bearer token and acts as
you, in your workspace.

```bash
OPENSEO_API_KEY=oseo_... DEEPSEEK_API_KEY=sk-... ruby examples/analytics/seo_agent.rb "..."
```

## Getting an API key

1. Sign up at [openseo.so](https://openseo.so) (or run your own instance —
   see OpenSEO's [`docs/SELF_HOSTING_DOCKER.md`](https://github.com/every-app/open-seo/blob/main/docs/SELF_HOSTING_DOCKER.md)).
2. In the app, open **Settings -> API keys**, create one, and copy it —
   it's shown once.
3. Export it as `OPENSEO_API_KEY`.

Self-hosting instead of using the hosted service? Point `OPENSEO_MCP_URL` at
your own deployment's `/mcp` endpoint — nothing else in `seo_agent.rb` changes,
same as swapping `MCP_URL` in `repo-explorer/`.

## What OpenSEO's MCP exposes

Keyword research with volume/difficulty/CPC, live SERP results, rank
tracking, domain and backlink overview, competitor comparison, site audits,
and (when connected) first-party Google Search Console data. The full list
is in [OpenSEO's MCP docs](https://github.com/every-app/open-seo/blob/main/web/content/docs/mcp.md).

## Egress guard — read this

Like every MCP `http`/`sse` instance, the call to `OPENSEO_MCP_URL` goes
through the same egress guard as a `data_tool`: **public HTTPS only** by
default. The hosted `https://app.openseo.so/mcp` clears that with no
configuration; a self-hosted instance behind `http://` or a private IP needs
the same deployment-level opt-in (`INSIKA_EGRESS_ALLOW_HTTP` /
`INSIKA_EGRESS_ALLOW_PRIVATE`, see [`docs/DEPLOY.md`](../../docs/DEPLOY.md))
data-tool's README covers for its own endpoint.

## Notes

- The `Authorization` header is masked as `__OCULTO__` everywhere the instance
  is displayed (CLI, API, Studio) once it's saved — see
  [MCP servers](../../docs/TOOLS.md#mcp-servers).
- An API key acts as *you* — anything the agent does through it happens in
  your OpenSEO workspace. Scope the key and the agent's instructions
  accordingly before pointing this at a real account.
- No `OPENSEO_API_KEY` set → the process raises on boot (`ENV.fetch` with no
  default), not a silent unauthenticated call.
