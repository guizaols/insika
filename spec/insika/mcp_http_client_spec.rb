# frozen_string_literal: true

require "spec_helper"
require "json"

# MINIMAL MCP client over HTTP JSON-RPC. Discovers tools via POST
# `tools/list` behind the egress guard. Bounded scope: a single stateless POST (no
# real MCP session lifecycle —/out-of-scope).
RSpec.describe Insika::McpHttpClient do
  # fake http: records the request, returns the configured result.
  class FakeRpcHttp
    attr_reader :last

    def initialize(result) = (@result = result)
    def request(**req) = (@last = req; @result)
  end

  AllowEgress = Class.new { def violation(*, **) = nil }.new
  BlockEgress = Class.new { def violation(*, **) = "private-network destination blocked" }.new

  def client(result:, egress: AllowEgress, **over)
    http = FakeRpcHttp.new(result)
    [Insika::McpHttpClient.new(url: "https://mcp.test/rpc", http: http, egress: egress, **over), http]
  end

  it "does a JSON-RPC tools/list POST and returns the tool list" do
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

  it "no tools in the result -> [] (does not raise)" do
    cli, = client(result: { status: 200, body: JSON.generate(result: {}) })
    expect(cli.list_tools).to eq([])
  end

  it "egress blocked -> Insika::Error (SSRF)" do
    cli, = client(result: { status: 200, body: "{}" }, egress: BlockEgress)
    expect { cli.list_tools }.to raise_error(Insika::Error, /blocked/)
  end

  it "HTTP >= 400 -> Insika::Error" do
    cli, = client(result: { status: 500, body: "boom" })
    expect { cli.list_tools }.to raise_error(Insika::Error, /MCP HTTP 500/)
  end

  it "JSON-RPC error in the envelope -> Insika::Error" do
    body = JSON.generate(jsonrpc: "2.0", id: 1, error: { code: -32_601, message: "Method not found" })
    cli, = client(result: { status: 200, body: body })
    expect { cli.list_tools }.to raise_error(Insika::Error, /Method not found/)
  end

  it "non-JSON response -> Insika::Error" do
    cli, = client(result: { status: 200, body: "<html>nope" })
    expect { cli.list_tools }.to raise_error(Insika::Error, /not JSON/)
  end
end
