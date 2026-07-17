# frozen_string_literal: true

require "json"

module Harness
  # MINIMAL MCP client over HTTP JSON-RPC (Phase 7, Stage E). Discovers the tools
  # of an MCP instance with HTTP transport by making a JSON-RPC 2.0 `tools/list`
  # POST to the instance endpoint, behind the EgressGuard (SSRF — the url comes
  # from editable config, NF4). It is the DEFAULT client injected into the
  # McpToolIngestor; tests pass a Fake (duck-typed) in its place.
  #
  # Contract (MCP client duck-type): `#list_tools -> [{name, description,
  # inputSchema}]` — the same MCP envelope that the ToolManifest adapter normalizes.
  #
  # SCOPE (bounded, D8): only the minimal handshake of ONE stateless `tools/list`
  # POST. Does NOT implement the full MCP session lifecycle (initialize/protocol
  # negotiation/session-id/notifications) nor the stdio transport — that is the
  # "real MCP transport", later work (out-of-scope, see spec §4 D8). It serves
  # simple HTTP MCP servers (direct JSON-RPC) and proves the ingestion seam.
  class McpHttpClient
    JSONRPC_VERSION = "2.0"

    def initialize(url:, http: Harness::HttpClient.new, egress: Harness::EgressGuard,
                   egress_options: {}, headers: {}, timeout: nil)
      @url = url.to_s
      @http = http
      @egress = egress
      @egress_options = egress_options
      @headers = { "Content-Type" => "application/json", "Accept" => "application/json" }.merge(headers || {})
      @timeout = timeout
    end

    # -> [ { "name", "description", "inputSchema" } ]. Raises Harness::Error on
    # blocked egress, HTTP != 2xx, invalid JSON or a JSON-RPC error.
    def list_tools
      reason = @egress.violation(@url, **@egress_options)
      raise Harness::Error, "MCP target blocked: #{reason}" if reason

      result = @http.request(method: "POST", url: @url, headers: @headers,
                             body: request_body("tools/list", {}), timeout: @timeout)
      Array(rpc_result(result).fetch("tools", []))
    end

    private

    def request_body(method, params)
      JSON.generate(jsonrpc: JSONRPC_VERSION, id: 1, method: method, params: params)
    end

    # Validates the JSON-RPC envelope and returns `result` (Hash). HTTP/parse/error -> Error.
    def rpc_result(result)
      status = result[:status].to_i
      raise Harness::Error, "MCP HTTP #{status}: #{result[:body].to_s[0, 200]}" if status >= 400

      parsed = begin
        JSON.parse(result[:body].to_s)
      rescue JSON::ParserError => e
        raise Harness::Error, "resposta MCP não é JSON: #{e.message}"
      end
      if (err = parsed["error"])
        raise Harness::Error, "MCP JSON-RPC error: #{err["message"] || err.inspect}"
      end

      parsed["result"] || {}
    end
  end
end
