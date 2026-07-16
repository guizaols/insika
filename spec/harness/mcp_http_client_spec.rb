# frozen_string_literal: true

require "spec_helper"
require "json"

# Fase 7, Etapa E: cliente MCP MÍNIMO sobre HTTP JSON-RPC. Descobre tools via POST
# `tools/list` atrás do egress guard. Escopo bounded: um POST stateless (sem o
# ciclo de sessão MCP real — D8/out-of-scope).
RSpec.describe Harness::McpHttpClient do
  # http fake: grava a request, devolve o resultado configurado.
  class FakeRpcHttp
    attr_reader :last

    def initialize(result) = (@result = result)
    def request(**req) = (@last = req; @result)
  end

  AllowEgress = Class.new { def violation(*, **) = nil }.new
  BlockEgress = Class.new { def violation(*, **) = "destino em rede privada bloqueado" }.new

  def client(result:, egress: AllowEgress, **over)
    http = FakeRpcHttp.new(result)
    [Harness::McpHttpClient.new(url: "https://mcp.test/rpc", http: http, egress: egress, **over), http]
  end

  it "faz POST JSON-RPC tools/list e devolve a lista de tools" do
    body = JSON.generate(jsonrpc: "2.0", id: 1,
                         result: { tools: [{ "name" => "search", "description" => "d",
                                             "inputSchema" => { "type" => "object" } }] })
    cli, http = client(result: { status: 200, body: body })

    tools = cli.list_tools

    expect(tools.map { |t| t["name"] }).to eq(["search"])
    expect(http.last[:method]).to eq("POST")
    sent = JSON.parse(http.last[:body])
    expect(sent["method"]).to eq("tools/list")
  end

  it "sem tools no result -> [] (não levanta)" do
    cli, = client(result: { status: 200, body: JSON.generate(result: {}) })
    expect(cli.list_tools).to eq([])
  end

  it "egress bloqueado -> Harness::Error (SSRF, NF4)" do
    cli, = client(result: { status: 200, body: "{}" }, egress: BlockEgress)
    expect { cli.list_tools }.to raise_error(Harness::Error, /bloqueado/)
  end

  it "HTTP >= 400 -> Harness::Error" do
    cli, = client(result: { status: 500, body: "boom" })
    expect { cli.list_tools }.to raise_error(Harness::Error, /MCP HTTP 500/)
  end

  it "erro JSON-RPC no envelope -> Harness::Error" do
    body = JSON.generate(jsonrpc: "2.0", id: 1, error: { code: -32_601, message: "Method not found" })
    cli, = client(result: { status: 200, body: body })
    expect { cli.list_tools }.to raise_error(Harness::Error, /Method not found/)
  end

  it "resposta não-JSON -> Harness::Error" do
    cli, = client(result: { status: 200, body: "<html>nope" })
    expect { cli.list_tools }.to raise_error(Harness::Error, /não é JSON/)
  end
end
