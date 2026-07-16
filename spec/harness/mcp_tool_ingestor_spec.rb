# frozen_string_literal: true

require "spec_helper"
require "json"
require "harness/tools/data_defined_tool" # o overlay carrega lazy; explícito no teste

# Fase 7, Etapa E: ingestão MCP LIVE. O ingestor descobre as tools de uma
# instância MCP via cliente INJETÁVEL (Fake), constrói um ToolManifest reusando o
# adapter MCP (inputSchema) e ingere pelo caminho da Etapa B (:import_tools: upsert
# + reload hot). Prova: group mcp:<instância>, binding JSON-RPC tools/call, corte
# de nome inválido (R4), e que o binding RODA no caminho HTTP das data-tools.
RSpec.describe Harness::McpToolIngestor do
  # Cliente MCP fake (duck-type): #list_tools -> [{name, description, inputSchema}].
  FakeMcpClient = Struct.new(:tools) do
    def list_tools = tools
  end

  # egress permissivo (não queremos DNS real no teste do binding).
  IngestorPermissiveEgress = Class.new { def violation(*, **) = nil }.new

  let(:mcp_store) { Harness::McpStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:tool_store) { Harness::ToolStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:base) { Harness::ToolRegistry.new }
  let(:overlay) { Harness::OverlayToolRegistry.new(base: base, tool_store: tool_store, http: Object.new) }
  let(:catalog) { Harness::ToolCatalog.new(tool_registry: overlay) }
  let(:events) { SpyEventStream.new }
  let(:import_tools) do
    Harness::Commands::ImportTools.new(tool_store: tool_store, registry: overlay,
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

  # ingestor com fábrica que devolve o Fake (o Command não injeta client -> usa a fábrica).
  def ingestor(tools: mcp_tools)
    described_class.new(mcp_store: mcp_store, import_tools: import_tools,
                        client_factory: ->(_record) { FakeMcpClient.new(tools) })
  end

  def seed_instance(**over)
    mcp_store.upsert({ name: "tavily", transport: "http", url: "https://mcp.test/rpc",
                       enabled: true, env: { "API_KEY" => "k" } }.merge(over))
  end

  describe "#ingest (descoberta -> ingestão)" do
    before { seed_instance }

    it "descobre e ingere as tools MCP como data-tools (reload hot no overlay/catálogo)" do
      report = ingestor.ingest("tavily")

      expect(report[:instance]).to eq("tavily")
      expect(report[:created]).to contain_exactly("search", "extract")
      expect(report[:errors]).to be_empty
      expect(overlay.names).to include("search", "extract") # overlay recarregado (hot)
      expect(catalog.all.map(&:name)).to include("search")
    end

    it "marca cada tool com group mcp:<instância> (gating por grupo da Etapa C)" do
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["group"]).to eq("mcp:tavily")
      expect(tool_store.get_raw("extract")["group"]).to eq("mcp:tavily")
    end

    it "binding = POST JSON-RPC tools/call no endpoint da instância" do
      ingestor.ingest("tavily")
      req = tool_store.get_raw("search")["request"]
      expect(req["method"]).to eq("POST")
      expect(req["url"]).to eq("https://mcp.test/rpc")

      body = JSON.parse(req["body"].gsub(/\{\{\w+\}\}/, "null")) # neutraliza os placeholders p/ parsear
      expect(body).to include("jsonrpc" => "2.0", "method" => "tools/call")
      expect(body["params"]["name"]).to eq("search") # nome real do MCP, literal
    end

    it "preserva o inputSchema (adapter MCP) como parameters JSON Schema" do
      ingestor.ingest("tavily")
      params = tool_store.get_raw("search")["parameters"]
      expect(params["properties"]).to have_key("query")
      expect(params["required"]).to eq(["query"])
    end

    it "tools/call é side_effect (checkpoint/skip-on-resume)" do
      ingestor.ingest("tavily")
      expect(tool_store.get_raw("search")["side_effect"]).to be(true)
    end

    it "idempotente: re-ingerir reconcilia (updated, não created)" do
      ingestor.ingest("tavily")
      report = ingestor.ingest("tavily")
      expect(report[:created]).to be_empty
      expect(report[:updated]).to contain_exactly("search", "extract")
    end
  end

  describe "binding roda no caminho HTTP das data-tools (prova end-to-end)" do
    before { seed_instance }

    it "interpola os argumentos do modelo no envelope JSON-RPC tools/call" do
      ingestor.ingest("tavily")
      defn = Harness::ToolDefinition.from_h(tool_store.get_raw("search"))
      captured = Class.new do
        attr_reader :last
        def request(**req) = (@last = req; { status: 200, body: "{}" })
      end.new
      tool = Harness::Tools::DataDefinedTool.new(definition: defn, http: captured, egress: IngestorPermissiveEgress)

      tool.execute(query: "gatos fofos", max: 3)

      sent = JSON.parse(captured.last[:body])
      expect(sent["method"]).to eq("tools/call")
      expect(sent["params"]["name"]).to eq("search")
      expect(sent["params"]["arguments"]).to eq("query" => "gatos fofos", "max" => 3)
    end
  end

  describe "corte de nome/schema inválido (R4)" do
    before { seed_instance }

    it "tool com nome fora do NAME_RE é ISOLADA em errors[], não derruba as demais" do
      tools = mcp_tools + [{ "name" => "Web-Search", "description" => "x",
                             "inputSchema" => { "type" => "object", "properties" => {} } }]
      report = ingestor(tools: tools).ingest("tavily")
      expect(report[:created]).to contain_exactly("search", "extract")
      expect(report[:errors].map { |e| e[:tool] }).to eq(["Web-Search"])
    end
  end

  describe "#manifest_for (sem ingerir)" do
    it "aceita cliente injetado diretamente (seam p/ transporte real futuro)" do
      seed_instance
      manifest = described_class.new(mcp_store: mcp_store, import_tools: import_tools)
                                .manifest_for("tavily", client: FakeMcpClient.new(mcp_tools))
      expect(manifest["defaults"]["group"]).to eq("mcp:tavily")
      expect(manifest["tools"].map { |t| t["name"] }).to contain_exactly("search", "extract")
    end
  end

  describe "validação da instância" do
    it "instância inexistente -> NotFoundError" do
      expect { ingestor.ingest("nope") }.to raise_error(Harness::NotFoundError, /não encontrada/)
    end

    it "instância desabilitada -> ValidationError" do
      seed_instance(enabled: false)
      expect { ingestor.ingest("tavily") }.to raise_error(Harness::ValidationError, /desabilitada/)
    end

    it "instância sem url (stdio) -> ValidationError (transport real é posterior — D8)" do
      seed_instance(url: nil, transport: "stdio", command: "npx foo")
      expect { ingestor.ingest("tavily") }.to raise_error(Harness::ValidationError, /sem url.*stdio/m)
    end
  end
end
