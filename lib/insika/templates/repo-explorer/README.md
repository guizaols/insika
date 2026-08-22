# repo-explorer

**MCP trail (http).** A live MCP tool-loop over Streamable HTTP:
the agent calls a real, running MCP server's tools — not a snapshot, not a
hand-rolled HTTP wrapper. The default target is
[DeepWiki's public MCP server](https://mcp.deepwiki.com/mcp), which needs
no API key for public repos.

```bash
DEEPSEEK_API_KEY=sk-... ruby repo-explorer/agent.rb "how does rails/rails route a request?"
```

This is not a DeepWiki showcase — it's exactly how you plug **any** MCP
server into an agent:

```bash
MCP_URL=https://your-mcp-server/mcp DEEPSEEK_API_KEY=sk-... ruby repo-explorer/agent.rb "..."
```

Point `MCP_URL` at any Streamable HTTP or SSE MCP server and nothing else
in `agent.rb` changes — swap the URL, rewrite the instructions for the new
server's tools, done.

## Under the hood

`mcp "repo-docs", transport: :http, url: …` declares the instance; the
engine connects live, discovers its tools (`read_wiki_structure`,
`read_wiki_contents`, `ask_question`), and wires them straight into the
agent's tool-loop with group `mcp:repo-docs`. Declaring an `mcp` inside an
agent's block auto-grants that agent access to the group — see
`lib/insika/dsl.rb`'s `mcp` method if you're curious why that matters.

A public HTTPS target needs no extra configuration (same egress guard as
any data-tool). A target on a private network needs the same
`INSIKA_EGRESS_ALLOW_PRIVATE`/`INSIKA_EGRESS_HOSTS` env vars a data-tool
would.
