# frozen_string_literal: true

# analytics — an MCP tool-loop over http against a real, third-party analytics
# server: OpenSEO (https://github.com/every-app/open-seo), an open-source
# SEO tool. Unlike the keyless demos in data-tool/ and repo-explorer/, OpenSEO
# is account-scoped: every call acts as you, in your workspace, so it needs an
# API key. That's the point of this example — MCP wired to a server with real
# auth, not just a public no-key toy.
#
#   OPENSEO_API_KEY=oseo_... DEEPSEEK_API_KEY=sk-... ruby examples/analytics/seo_agent.rb "..."
#
# Point OPENSEO_MCP_URL at a self-hosted instance instead of the hosted one —
# nothing else in this file changes.
require_relative "../../lib/insika"

seo = Insika.agent("seo-analyst") do
  model "deepseek-v4-flash"
  provider :deepseek

  instructions <<~PROMPT
    You are an SEO analyst working from OpenSEO's MCP tools: keyword research,
    SERP inspection, rank tracking, domain/backlink overview, and site audits.
    Always call a tool to get real numbers (search volume, rank position,
    backlink counts, audit findings) — never estimate or invent SEO data.
    If a tool needs a project ID and none was given, list the user's OpenSEO
    projects first and ask which one applies before continuing.
  PROMPT

  # http transport, auth via header — the pattern for any MCP server that
  # requires a key instead of being open to the public. Swap OPENSEO_MCP_URL
  # for a self-hosted OpenSEO deployment and nothing else here changes.
  mcp "openseo", transport: :http,
      url: ENV.fetch("OPENSEO_MCP_URL", "https://app.openseo.so/mcp"),
      headers: { "Authorization" => "Bearer #{ENV.fetch('OPENSEO_API_KEY')}" }
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.delete("--serve")
    seo.serve
  else
    message = ARGV.join(" ")
    message = "List my OpenSEO projects, then research 5 keyword opportunities for the first one." if message.empty?
    puts seo.reply(message)
  end
end

seo
