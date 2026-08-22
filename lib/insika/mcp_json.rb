# frozen_string_literal: true

require "json"

module Insika
  # The de-facto `mcpServers` JSON format every MCP client (Claude Desktop,
  # Cursor, ...) already uses — one parser shared by all three PR3 config
  # surfaces (CLI `insika mcp import`, the API `/v1/mcp` PUT, Studio's "Import
  # JSON" textarea).
  #
  #   {
  #     "mcpServers": {
  #       "tavily":     { "url": "https://mcp.tavily.com/mcp", "headers": {...} },
  #       "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] }
  #     }
  #   }
  #
  # A server entry with `command` and no `url` is stdio; one with `url` and no
  # `command` is `http` (Streamable HTTP, the modern default) unless it names
  # `"transport": "sse"` explicitly — the bare format has no other way to spell
  # SSE. `export` always writes `transport` back so a round-trip is lossless.
  module McpJson
    module_function

    # `json` — a JSON string or an already-parsed Hash (either key type).
    # Upserts every entry via `mcp_store` (per-key secret reconciliation, same
    # as any other upsert — re-importing an export's `__OCULTO__` sentinel
    # preserves whatever is already stored, never wipes it).
    # -> [Hash] the masked upserted records, in the document's key order.
    def import(json, mcp_store:)
      data = json.is_a?(String) ? JSON.parse(json) : stringify(json)
      servers = stringify(data["mcpServers"] || {})
      servers.map { |name, cfg| mcp_store.upsert(attrs_from(name, stringify(cfg))) }
    end

    # -> { "mcpServers" => { name => {...} } }, secrets masked (never plaintext
    # — `mcp_store.all` already masks, this only reshapes).
    def export(mcp_store:)
      { "mcpServers" => mcp_store.all.each_with_object({}) { |record, acc| acc[record["name"]] = server_from(record) } }
    end

    def attrs_from(name, cfg)
      {
        name: name.to_s,
        transport: presence(cfg["transport"]) || (presence(cfg["command"]) ? "stdio" : "http"),
        command: cfg["command"], args: cfg["args"], url: cfg["url"],
        headers: cfg["headers"], env: cfg["env"],
        description: cfg["description"], enabled: cfg.fetch("enabled", true)
      }
    end
    private_class_method :attrs_from

    def server_from(record)
      body = record["transport"] == "stdio" ? { "command" => record["command"], "args" => record["args"], "env" => record["env"] }
                                             : { "url" => record["url"], "headers" => record["headers"] }
      body.merge(
        "transport" => record["transport"],
        "description" => record["description"],
        "enabled" => record["enabled"]
      ).compact
    end
    private_class_method :server_from

    def stringify(obj)
      return {} unless obj.is_a?(Hash)

      obj.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
    private_class_method :stringify

    def presence(value) = Insika::Coercion.presence(value)
    private_class_method :presence
  end
end
