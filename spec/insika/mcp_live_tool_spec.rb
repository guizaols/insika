# frozen_string_literal: true

require "spec_helper"
require "insika/mcp_live_tool" # the registry loads it lazily; explicit in the test

# One live MCP tool call. name/description/parameters_schema come
# from the cached descriptor; #execute is the only thing that reaches the
# client, and — like every tool in this codebase — never raises.
RSpec.describe Insika::McpLiveTool do
  FakeGemTool = Struct.new(:reply) do
    attr_accessor :name
    def call(**params) = reply.is_a?(Exception) ? raise(reply) : reply
  end

  def build(tool_hash, gem_tool)
    gem_tool.name = tool_hash.fetch("name")
    described_class.new(instance_name: "fs", tool: tool_hash, client_for: -> { double_client(gem_tool) })
  end

  def double_client(gem_tool)
    Class.new { define_method(:tools) { [gem_tool].compact } }.new
  end

  it "name/description/parameters_schema come from the cached descriptor" do
    tool = build({ "name" => "list_files", "description" => "Lists files",
                   "inputSchema" => { "type" => "object", "properties" => { "path" => { "type" => "string" } } } },
                 FakeGemTool.new({}))

    expect(tool.name).to eq("list_files")
    expect(tool.description).to eq("Lists files")
    expect(tool.parameters_schema).to eq("type" => "object", "properties" => { "path" => { "type" => "string" } })
  end

  it "a blank inputSchema defaults to an empty object schema" do
    tool = build({ "name" => "x", "description" => "d", "inputSchema" => {} }, FakeGemTool.new({}))
    expect(tool.parameters_schema).to eq("type" => "object", "properties" => {})
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

  # WHAT THE DEPLOYMENT TRUSTS A TOOL WITH. A server describes what its tools do; it
  # cannot say which of its results are evidence or which parameters may only carry
  # an id something already returned — only the deployment can, so those come from
  # the instance's configuration and the envelope reads them off the tool like any
  # other.
  describe "the per-tool overrides" do
    let(:search) do
      { "name" => "search_products", "description" => "busca",
        "inputSchema" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } }
    end
    let(:add) do
      { "name" => "add_to_cart", "description" => "adiciona",
        "inputSchema" => { "type" => "object", "properties" => { "product_id" => { "type" => "string" } } } }
    end

    def tool(descriptor, overrides, result: nil)
      client = Object.new
      live = Object.new
      live.define_singleton_method(:name) { descriptor.fetch("name") }
      live.define_singleton_method(:call) { |**| result }
      client.define_singleton_method(:tools) { [live] }
      described_class.new(instance_name: "store", tool: descriptor, overrides: overrides,
                          client_for: -> { client })
    end

    it "carries an evidence spec that names the store's own field names" do
      spec = tool(search, { "evidence" => { "kind" => "products", "items" => "products",
                                            "id" => "product_id", "line" => "name" } }).evidence
      expect(spec.kind).to eq("products")
      expect([spec.items_path, spec.id_field, spec.line_field]).to eq(%w[products product_id name])
    end

    it "carries a provenance requirement the envelope can gate on" do
      expect(tool(add, { "requires_evidence" => ["product_id"] }).requires_evidence)
        .to eq({ "params" => ["product_id"] })
    end

    it "refuses a requirement naming a parameter the tool does not declare" do
      expect { tool(add, { "requires_evidence" => ["sku"] }) }
        .to raise_error(Insika::ValidationError, /declared top-level parameters/)
    end

    it "a tool nobody configured answers neither, exactly as before" do
      plain = tool(search, {})
      expect(plain.evidence).to be_nil
      expect(plain.requires_evidence).to be_nil
    end

    # MCP answers in text. Only a tool someone declared evidence for is parsed, so
    # every other tool's bytes reach the model unchanged.
    it "parses the result into an object only when there is evidence to extract" do
      body = JSON.generate("products" => [{ "product_id" => "SKU-1", "name" => "Creme" }])
      extracted = tool(search, { "evidence" => { "kind" => "products", "items" => "products" } }, result: body)
      plain = tool(search, {}, result: body)

      expect(extracted.execute(query: "creme")).to eq("products" => [{ "product_id" => "SKU-1", "name" => "Creme" }])
      expect(plain.execute(query: "creme")).to eq(body)
    end

    # The gem hands back its own content object, not a String — the shape that made
    # a working store read to the model as "the catalogue is down".
    it "reads the text out of the gem's content object too" do
      body = JSON.generate("products" => [{ "product_id" => "SKU-1" }])
      content = Object.new
      content.define_singleton_method(:text) { body }
      out = tool(search, { "evidence" => { "kind" => "products", "items" => "products" } }, result: content)
                .execute(query: "creme")
      expect(out).to eq("products" => [{ "product_id" => "SKU-1" }])
    end

    it "text that is not JSON stays the text it was" do
      out = tool(search, { "evidence" => { "kind" => "products" } }, result: "nada encontrado").execute(query: "x")
      expect(out).to eq("nada encontrado")
    end
  end
end
