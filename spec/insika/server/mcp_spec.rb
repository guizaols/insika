# frozen_string_literal: true

require "spec_helper"
require "async"
require_relative "../../../lib/insika/server/app"

# The MCP server end to end through the App: the JSON-RPC lifecycle a client
# (Claude Code, Cursor, the MCP Inspector) runs, over real in-memory stores.
RSpec.describe Insika::Server::Mcp do
  let(:token) { "mcp-sekret" }
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }
  let(:tasks) { Insika::TaskStore.new(store: backend) }
  let(:app) do
    Insika::Server::App.new(command_bus: ServerBusDouble.new, event_stream: ServerEventStreamDouble.new,
                            session_store: sessions, task_store: tasks,
                            config: { sync_timeout: 0.05, gateway_token: token })
  end

  def post(body, auth: token)
    env = Rack::MockRequest.env_for("/mcp", method: "POST", input: body.is_a?(String) ? body : JSON.generate(body))
    env["HTTP_AUTHORIZATION"] = "Bearer #{auth}" if auth
    status, headers, chunks = app.call(env)
    text = chunks.to_a.join
    [status, headers, text.empty? ? nil : JSON.parse(text)]
  end

  def rpc(method, params = nil, id: 1)
    post({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }.compact)[2]
  end

  before do
    sessions.create(id: "s-1", vars: { "agent" => "shop" })
    sessions.append_messages("s-1", [{ "role" => "user", "content" => "oi" }])
    tasks.create(command: { "type" => "send_message" }, session_id: "s-1")
  end

  it "refuses a request without the gateway token" do
    expect(post({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }, auth: nil)[0]).to eq(401)
  end

  it "negotiates the protocol version and advertises tools" do
    result = rpc("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {},
                                 "clientInfo" => { "name" => "spec", "version" => "0" } })["result"]
    expect(result).to include("protocolVersion" => "2025-03-26", "capabilities" => { "tools" => { "listChanged" => false } })
    expect(result["serverInfo"]).to include("name" => "insika", "version" => Insika::VERSION)
  end

  it "falls back to its newest version for one it does not speak" do
    expect(rpc("initialize", { "protocolVersion" => "1999-01-01" })["result"]["protocolVersion"]).to eq("2025-06-18")
  end

  it "answers a notification with 202 and no body" do
    status, _, body = post({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })
    expect([status, body]).to eq([202, nil])
  end

  it "lists four read-only tools, each with an input schema" do
    tools = rpc("tools/list")["result"]["tools"]
    expect(tools.map { _1["name"] }).to eq(%w[agent_summary list_sessions get_transcript list_flags])
    expect(tools).to all(include("inputSchema" => hash_including("type" => "object"),
                                 "annotations" => hash_including("readOnlyHint" => true)))
  end

  it "returns tool data as text and structured content" do
    result = rpc("tools/call", { "name" => "agent_summary", "arguments" => {} })["result"]
    expect(result["structuredContent"]["items"].first).to include("agent" => "shop", "turns" => 1)
    expect(JSON.parse(result["content"].first["text"])).to eq(result["structuredContent"])
  end

  it "reports a missing session as a tool error, not a protocol error" do
    result = rpc("tools/call", { "name" => "get_transcript", "arguments" => { "session_id" => "nope" } })["result"]
    expect(result).to include("isError" => true)
  end

  it "rejects bad arguments with invalid params" do
    error = rpc("tools/call", { "name" => "list_sessions", "arguments" => { "limit" => 0 } })["error"]
    expect(error["code"]).to eq(-32_602)
  end

  it "rejects an unknown tool with invalid params" do
    expect(rpc("tools/call", { "name" => "drop_tables" })["error"]["code"]).to eq(-32_602)
  end

  it "rejects an unknown method" do
    expect(rpc("resources/list")["error"]["code"]).to eq(-32_601)
  end

  it "answers malformed JSON with a parse error" do
    status, _, body = post("{nope")
    expect([status, body["error"]["code"]]).to eq([400, -32_700])
  end

  it "has no server-initiated stream" do
    env = Rack::MockRequest.env_for("/mcp", method: "GET")
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    expect(app.call(env)[0]).to eq(405)
  end
end
