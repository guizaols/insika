# browser-agent

**MCP trail (stdio).** A live MCP tool-loop over stdio (RFC-0040): the
engine spawns [Playwright's MCP server](https://github.com/microsoft/playwright-mcp)
(`npx @playwright/mcp@latest`) as a child process and wires its browser
tools straight into the agent's tool-loop. No API key beyond your LLM
provider's.

## Before you run it

Two things this template needs beyond the gem and a provider key:

1. **Node.js and npm** — `npx` spawns the MCP server as a child process.
2. **`INSIKA_MCP_STDIO=1`** — a stdio MCP instance is arbitrary command
   execution by config, so the engine refuses to start it until you opt in
   explicitly (same discipline as the egress env vars for private hosts).

```bash
node --version   # confirm Node.js is installed
INSIKA_MCP_STDIO=1 DEEPSEEK_API_KEY=sk-... ruby browser-agent/agent.rb "go to example.com and summarize the page"
```

Without `INSIKA_MCP_STDIO=1` the reply will say the tool call failed —
that's the gate working, not a bug.

## Swap the server

This is not a Playwright showcase — it's exactly how you plug **any** MCP
server into an agent over stdio:

```bash
MCP_COMMAND=your-mcp-server MCP_ARGS="--flag value" INSIKA_MCP_STDIO=1 DEEPSEEK_API_KEY=sk-... ruby browser-agent/agent.rb "..."
```

Point `MCP_COMMAND`/`MCP_ARGS` at any stdio MCP server and rewrite the
instructions for its tools — nothing else in `agent.rb` changes.
