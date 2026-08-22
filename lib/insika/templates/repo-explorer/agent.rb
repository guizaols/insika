# frozen_string_literal: true

# ---
# title: Repo Explorer
# trail: MCP
# description: Live MCP tool-loop over http — answers questions about any public GitHub repo via a keyless public MCP server. Point MCP_URL at any other MCP server instead.
# capabilities: mcp, http
# ---
#
# repo-explorer — a live MCP tool-loop over HTTP: the agent calls
# a real MCP server's tools (read_wiki_structure, read_wiki_contents,
# ask_question) to answer questions about a public GitHub repo. The default
# target is DeepWiki's public, keyless MCP server — swap MCP_URL for any
# other MCP server and nothing else in this file changes.
#
#   DEEPSEEK_API_KEY=sk-... ruby repo-explorer/agent.rb "how does rails/rails route a request?"
#   MCP_URL=https://your-mcp-server/mcp DEEPSEEK_API_KEY=sk-... ruby repo-explorer/agent.rb "..."
require "insika"

repo = Insika.agent("repo-explorer") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You answer questions about public GitHub repositories using the
    repo-docs MCP tools (read_wiki_structure, read_wiki_contents,
    ask_question). Repos are named "owner/repo" (e.g. "rails/rails"). Never
    answer from your own training data when a tool can check — call
    ask_question first.
  PROMPT

  mcp "repo-docs", transport: :http, url: ENV.fetch("MCP_URL", "https://mcp.deepwiki.com/mcp")
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    repo.serve
  else
    message = ARGV.join(" ")
    message = "In the rails/rails repo, how does routing work? One paragraph." if message.empty?
    puts repo.reply(message)
  end
end

repo
