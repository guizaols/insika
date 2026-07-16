# frozen_string_literal: true

require "json"

module Harness
  # Cliente MCP MÍNIMO sobre HTTP JSON-RPC (Fase 7, Etapa E). Descobre as tools de
  # uma instância MCP com transport HTTP fazendo um POST JSON-RPC 2.0 `tools/list`
  # no endpoint da instância, atrás do EgressGuard (SSRF — a url vem de config
  # editável, NF4). É o cliente DEFAULT injetado no McpToolIngestor; os testes
  # passam um Fake (duck-typed) no lugar.
  #
  # Contrato (duck-type do cliente MCP): `#list_tools -> [{name, description,
  # inputSchema}]` — o mesmo envelope MCP que o adapter do ToolManifest normaliza.
  #
  # ESCOPO (bounded, D8): só o handshake mínimo de UM POST stateless `tools/list`.
  # NÃO implementa o ciclo de sessão MCP completo (initialize/negociação de
  # protocolo/session-id/notifications) nem transport stdio — isso é o "transporte
  # MCP real", trabalho posterior (out-of-scope, ver a spec §4 D8). Serve para
  # servidores MCP HTTP simples (JSON-RPC direto) e para provar o seam de ingestão.
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

    # -> [ { "name", "description", "inputSchema" } ]. Levanta Harness::Error em
    # egress bloqueado, HTTP != 2xx, JSON inválido ou erro JSON-RPC.
    def list_tools
      reason = @egress.violation(@url, **@egress_options)
      raise Harness::Error, "destino MCP bloqueado: #{reason}" if reason

      result = @http.request(method: "POST", url: @url, headers: @headers,
                             body: request_body("tools/list", {}), timeout: @timeout)
      Array(rpc_result(result).fetch("tools", []))
    end

    private

    def request_body(method, params)
      JSON.generate(jsonrpc: JSONRPC_VERSION, id: 1, method: method, params: params)
    end

    # Valida o envelope JSON-RPC e devolve `result` (Hash). HTTP/parse/erro -> Error.
    def rpc_result(result)
      status = result[:status].to_i
      raise Harness::Error, "MCP HTTP #{status}: #{result[:body].to_s[0, 200]}" if status >= 400

      parsed = begin
        JSON.parse(result[:body].to_s)
      rescue JSON::ParserError => e
        raise Harness::Error, "resposta MCP não é JSON: #{e.message}"
      end
      if (err = parsed["error"])
        raise Harness::Error, "erro JSON-RPC do MCP: #{err["message"] || err.inspect}"
      end

      parsed["result"] || {}
    end
  end
end
