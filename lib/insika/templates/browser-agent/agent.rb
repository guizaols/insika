# frozen_string_literal: true

# ---
# title: Browser Agent
# trail: MCP
# description: Live MCP tool-loop over stdio (RFC-0040) — navigates and summarizes a real webpage via Playwright's MCP server. Requires Node.js/npm and INSIKA_MCP_STDIO=1.
# capabilities: mcp, stdio
# env: INSIKA_MCP_STDIO
# requires: Node.js and npm (npx spawns the MCP server as a child process)
# ---
#
# browser-agent — a live MCP tool-loop over STDIO (RFC-0040): the agent
# drives a real, sandboxed browser through Playwright's MCP server
# (@playwright/mcp, no API key). stdio is arbitrary command execution by
# config, so it needs the operator's explicit opt-in (INSIKA_MCP_STDIO=1)
# and Node.js/npm on the machine — the two things this template needs
# beyond the gem and a provider key. Swap MCP_COMMAND/MCP_ARGS for any other
# MCP server and nothing else in this file changes.
#
#   INSIKA_MCP_STDIO=1 DEEPSEEK_API_KEY=sk-... ruby browser-agent/agent.rb "go to example.com and summarize the page"
require "insika"
require "shellwords"

browser = Insika.agent("browser-agent") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You browse the web using the browser MCP tools. Navigate to the
    requested page, then extract or summarize what was asked. Never invent
    page content — always navigate and read it first.
  PROMPT

  mcp "browser", transport: :stdio,
      command: ENV.fetch("MCP_COMMAND", "npx"),
      args: Shellwords.split(ENV.fetch("MCP_ARGS", "-y @playwright/mcp@latest"))
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    browser.serve
  else
    message = ARGV.join(" ")
    message = "Go to https://example.com and summarize the page in two sentences." if message.empty?
    puts browser.reply(message)
  end
end

browser
