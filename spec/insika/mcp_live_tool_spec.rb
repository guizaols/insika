# frozen_string_literal: true

require "spec_helper"
require "insika/mcp_live_tool" # the registry loads it lazily; explicit in the test

# One live MCP tool call. name/description/params_schema come
# from the cached descriptor; #execute is the only thing that reaches the
# client, and — like every tool in this codebase — never raises.
RSpec.describe Insika::McpLiveTool do
  FakeGemTool = Struct.new(:reply) do
    def execute(**params) = reply.is_a?(Exception) ? raise(reply) : reply
  end

  def build(tool_hash, gem_tool)
    described_class.new(instance_name: "fs", tool: tool_hash, client_for: -> { double_client(gem_tool) })
  end

  def double_client(gem_tool)
    Class.new { define_method(:tool) { |_name| gem_tool } }.new
  end

  it "name/description/params_schema come from the cached descriptor" do
    tool = build({ "name" => "list_files", "description" => "Lists files",
                   "inputSchema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } } },
                 FakeGemTool.new({}))

    expect(tool.name).to eq("list_files")
    expect(tool.description).to eq("Lists files")
    expect(tool.params_schema).to eq("type" => "object", "properties" => { "path" => { "type" => "string" } })
  end

  it "a blank inputSchema defaults to an empty object schema" do
    tool = build({ "name" => "x", "description" => "d", "inputSchema" => {} }, FakeGemTool.new({}))
    expect(tool.params_schema).to eq("type" => "object", "properties" => {})
  end

  it "delegates execute to the gem's own tool and returns its (already unwrapped) result verbatim" do
    tool = build({ "name" => "list_files", "description" => "d", "inputSchema" => {} },
                 FakeGemTool.new({ "content" => "unwrapped by the gem" }))
    expect(tool.execute(path: "/tmp")).to eq({ "content" => "unwrapped by the gem" })
  end

  it "the underlying tool no longer being offered -> {error:}, never raises" do
    described_tool = described_class.new(instance_name: "fs", tool: { "name" => "gone", "description" => "d" },
                                          client_for: -> { double_client(nil) })
    expect(described_tool.execute).to eq(error: "MCP instance 'fs' tool 'gone' failed: tool 'gone' no longer offered")
  end

  it "a raised error during execute -> {error:}, never raises" do
    tool = build({ "name" => "list_files", "description" => "d" }, FakeGemTool.new(RuntimeError.new("timeout")))
    expect(tool.execute).to eq(error: "MCP instance 'fs' tool 'list_files' failed: timeout")
  end

  it "a client_for that itself fails to connect -> {error:}, never raises" do
    tool = described_class.new(instance_name: "fs", tool: { "name" => "x", "description" => "d" },
                               client_for: -> { raise "connection refused" })
    expect(tool.execute).to eq(error: "MCP instance 'fs' tool 'x' failed: connection refused")
  end
end
