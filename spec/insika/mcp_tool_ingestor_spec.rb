# frozen_string_literal: true

require "spec_helper"
require "json"
require "insika/tools/data_defined_tool" # the overlay loads lazily; explicit in the test

# LIVE MCP ingestion. The ingestor discovers the tools of an MCP
# instance via an INJECTABLE client (Fake), builds a ToolManifest reusing the MCP
# adapter (inputSchema) and ingests through the path (import_tools: upsert
# + hot reload). Proof: group mcp:<instance>, JSON-RPC tools/call binding, invalid
# name cutoff (R4), and that the binding RUNS on the data-tools HTTP path.
RSpec.describe Insika::McpToolIngestor do
  # Fake MCP client (duck-type): #list_tools -> [{name, description, inputSchema}].
  FakeMcpClient = Struct.new(:tools) do
    def list_tools = tools
  end

  # permissive egress (we don't want real DNS in the binding test).
  IngestorPermissiveEgress = Class.new { def violation(*, **) = nil }.new

  let(:mcp_store) { Insika::McpStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:tool_store) { Insika::ToolStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:base) { Insika::ToolRegistry.new }
  let(:overlay) { Insika::OverlayToolRegistry.new(base: base, tool_store: tool_store, http: Object.new) }
  let(:catalog) { Insika::ToolCatalog.new(tool_registry: overlay) }
  let(:events) { SpyEventStream.new }
  let(:import_tools) do
    Insika::Commands::ImportTools.new(tool_store: tool_store, registry: overlay,
                                       tool_catalog: catalog, event_stream: events, secrets: {}, env: {})
  end

  let(:mcp_tools) do
    [
      { "name" => "search", "description" => "Busca na web",
        "inputSchema" => { "type" => "object",
                           "properties" => { "query" => { "type" => "string" }, "max" => { "type" => "integer" } },
                           "required" => ["query"] } },
      { "name" => "extract", "description" => "Extrai conteúdo",
        "inputSchema" => { "type" => "object",
                           "properties" => { "urls" => { "type" => "array", "items" => { "type" => "string" } } },
                           "required" => ["urls"] } }
    ]
  end

  # ingestor with a factory that returns the Fake (the Command doesn't inject a client -> uses the factory).
  def ingestor(tools: mcp_tools)
    described_class.new(mcp_store: mcp_store, import_tools: import_tools,
                        client_factory: ->(_record) { FakeMcpClient.new(tools) })
  end

  def seed_instance(**over)
    mcp_store.upsert({ name: "tavily", transport: "http", url: "https://mcp.test/rpc",
                       enabled: true, env: { "API_KEY" => "k" } }.merge(over))
  end

  describe "#ingest (discovery -> ingestion)" do
    before { seed_instance }

    it "discovers and ingests the MCP tools as data-tools (hot reload in overlay/catalog)" do
      report = ingestor.ingest("tavily")

      expect(report[:instance]).to eq("tavily")
      expect(report[:created]).to contain_exactly("search", "extract")
      expect(report[:errors]).to be_empty
      expect(overlay.names).to include("search", "extract") # overlay reloaded (hot)
      expect(catalog.all.map(&:name)).to include("search")
    end

    it "marks each tool with group mcp:<instance> (group gating from)" do
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["group"]).to eq("mcp:tavily")
      expect(tool_store.get_raw("extract")["group"]).to eq("mcp:tavily")
    end

    it "binding = JSON-RPC tools/call POST to the instance endpoint" do
      ingestor.ingest("tavily")
      req = tool_store.get_raw("search")["request"]
      expect(req["method"]).to eq("POST")
      expect(req["url"]).to eq("https://mcp.test/rpc")

      body = JSON.parse(req["body"].gsub(/\{\{\w+\}\}/, "null")) # neutralize the placeholders to parse
      expect(body).to include("jsonrpc" => "2.0", "method" => "tools/call")
      expect(body["params"]["name"]).to eq("search") # real MCP name, literal
    end

    it "preserves the inputSchema (MCP adapter) as parameters JSON Schema" do
      ingestor.ingest("tavily")
      params = tool_store.get_raw("search")["parameters"]
      expect(params["properties"]).to have_key("query")
      expect(params["required"]).to eq(["query"])
    end

    it "tools/call is side_effect (checkpoint/skip-on-resume)" do
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["side_effect"]).to be(true)
    end

    it "idempotent: re-ingesting reconciles (updated, not created)" do
      ingestor.ingest("tavily")
      report = ingestor.ingest("tavily")
      expect(report[:created]).to be_empty
      expect(report[:updated]).to contain_exactly("search", "extract")
    end
  end

  describe "binding runs on the data-tools HTTP path (end-to-end proof)" do
    before { seed_instance }

    it "interpolates the model arguments into the JSON-RPC tools/call envelope" do
      ingestor.ingest("tavily")
      defn = Insika::ToolDefinition.from_h(tool_store.get_raw("search"))
      captured = Class.new do
        attr_reader :last
        def request(**req) = (@last = req; { status: 200, body: "{}" })
      end.new
      tool = Insika::Tools::DataDefinedTool.new(definition: defn, http: captured, egress: IngestorPermissiveEgress)

      tool.execute(query: "gatos fofos", max: 3)

      sent = JSON.parse(captured.last[:body])
      expect(sent["method"]).to eq("tools/call")
      expect(sent["params"]["name"]).to eq("search")
      expect(sent["params"]["arguments"]).to eq("query" => "gatos fofos", "max" => 3)
    end
  end

  describe "invalid name/schema cutoff (R4)" do
    before { seed_instance }

    it "tool with a name outside NAME_RE is ISOLATED in errors[], does not take down the rest" do
      tools = mcp_tools + [{ "name" => "Web-Search", "description" => "x",
                             "inputSchema" => { "type" => "object", "properties" => {} } }]
      report = ingestor(tools: tools).ingest("tavily")
      expect(report[:created]).to contain_exactly("search", "extract")
      expect(report[:errors].map { |e| e[:tool] }).to eq(["Web-Search"])
    end
  end

  describe "#manifest_for (without ingesting)" do
    it "accepts a directly injected client (seam for a future real transport)" do
      seed_instance
      manifest = described_class.new(mcp_store: mcp_store, import_tools: import_tools)
                                .manifest_for("tavily", client: FakeMcpClient.new(mcp_tools))
      expect(manifest["defaults"]["group"]).to eq("mcp:tavily")
      expect(manifest["tools"].map { |t| t["name"] }).to contain_exactly("search", "extract")
    end
  end

  describe "credential injection (env -> HTTP headers)" do
    it "discovery (#list_tools) sends the instance's env as literal headers" do
      seed_instance(env: { "Authorization" => "Bearer xyz" })
      captured = nil
      client_factory = lambda do |record|
        captured = record
        FakeMcpClient.new(mcp_tools)
      end
      described_class.new(mcp_store: mcp_store, import_tools: import_tools,
                          client_factory: client_factory).ingest("tavily")
      # the factory receives the RAW record (real credentials) — for an http
      # instance that's `headers` (RFC-0040: `env` migrates to `headers` on
      # read for http/sse). The client itself is built from it by whoever the
      # factory is (default_client, in production).
      expect(captured["headers"]).to eq("Authorization" => "Bearer xyz")
    end

    it "the default client actually sends env as headers on tools/list" do
      seed_instance(env: { "Authorization" => "Bearer xyz" })
      http = Class.new do
        attr_reader :last_headers
        def request(**req) = (@last_headers = req[:headers]; { status: 200, body: '{"result":{"tools":[]}}' })
      end.new
      client = Insika::McpHttpClient.new(url: "https://mcp.test/rpc", http: http, egress: IngestorPermissiveEgress,
                                         headers: { "Authorization" => "Bearer xyz" })
      client.list_tools
      expect(http.last_headers["Authorization"]).to eq("Bearer xyz")
    end

    it "every INGESTED tool's binding carries the env headers (real tools/call, not just discovery)" do
      seed_instance(env: { "Authorization" => "Bearer xyz" })
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["request"]["headers"]).to include("Authorization" => "Bearer xyz")
    end

    it "no env -> unchanged (only Content-Type), byte-for-byte parity with before this fix" do
      seed_instance(env: {})
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["request"]["headers"]).to eq("Content-Type" => "application/json")
    end
  end

  describe "instance validation" do
    it "nonexistent instance -> NotFoundError" do
      expect { ingestor.ingest("nope") }.to raise_error(Insika::NotFoundError, /not found/)
    end

    it "disabled instance -> ValidationError" do
      seed_instance(enabled: false)
      expect { ingestor.ingest("tavily") }.to raise_error(Insika::ValidationError, /disabled/)
    end

    it "instance with no url (stdio) -> ValidationError (real transport comes later)" do
      seed_instance(url: nil, transport: "stdio", command: "npx foo")
      expect { ingestor.ingest("tavily") }.to raise_error(Insika::ValidationError, /no url.*stdio/m)
    end
  end
end
