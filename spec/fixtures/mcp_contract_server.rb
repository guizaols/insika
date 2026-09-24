# frozen_string_literal: true

require "json"

module McpContractServer
  module_function

  def reply(message, legacy: false)
    id = message["id"]
    return unless id

    result = case message["method"]
             when "server/discover"
               return { jsonrpc: "2.0", id: id, error: { code: -32601, message: "Method not found" } } if legacy
               { supportedVersions: ["2026-07-28"], capabilities: { tools: {} } }
             when "initialize"
               { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } }
             when "tools/list"
               { tools: [{ name: "echo", description: "Echo text", annotations: { readOnlyHint: true },
                           inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } }] }
             when "tools/call"
               text = message.dig("params", "arguments", "text")
               case text
               when "structured" then { structuredContent: { products: [{ id: "p1" }] }, content: [] }
               when "image"
                 { content: [{ type: "text", text: "image" },
                             { type: "image", mimeType: "image/png", data: "aGVsbG8=" }] }
               else { content: [{ type: "text", text: text }], isError: text == "fail" }
               end
             else {}
             end
    { jsonrpc: "2.0", id: id, result: result }
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  $stdin.each_line do |line|
    response = McpContractServer.reply(JSON.parse(line), legacy: ENV["MCP_LEGACY"] == "1")
    puts JSON.generate(response) if response
  end
end
