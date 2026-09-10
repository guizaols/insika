# frozen_string_literal: true

require "spec_helper"

# LIVE MCP tools — kills the snapshot. `entries` is cheap
# (McpStore#tools_cache only); `refresh` is the only thing that connects;
# execution (the factory) never depends on the cache and never breaks turn
# ASSEMBLY on a downed server — only that tool's own call.
RSpec.describe Insika::McpToolRegistry do
  # duck-typed MCP tool (RubyLLM::MCP::Tool's shape: name/description/params_schema/execute).
  FakeRegistryTool = Struct.new(:name, :description, :params_schema, :behavior) do
    def execute(**params)
      case behavior
      when :boom then raise "connection reset"
      else { echoed: params }
      end
    end
  end

  FakeRegistryClient = Struct.new(:tool_list, :start_error) do
    def alive? = @alive || false
    def start
      raise start_error if start_error

      @alive = true
    end

    def stop = @alive = false
    def tools = tool_list
    def tool(name) = tool_list.find { |t| t.name == name }
  end

  let(:mcp_store) { Insika::McpStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

  def seed(**over)
    mcp_store.upsert({ name: "fs", transport: "stdio", command: "npx", enabled: true }.merge(over))
  end

  describe "#entries" do
    it "is empty before any refresh (cache-only, no I/O)" do
      seed
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { raise "never called" })
      expect(registry.entries).to eq([])
    end

    it "one entry per cached tool, tagged with group mcp:<instance> and side_effect true" do
      seed
      mcp_store.set_tools_cache("fs", [{ "name" => "list_files", "description" => "d", "inputSchema" => {} }])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { raise "never called" })

      entry = registry.entries.first
      expect(entry.name).to eq("list_files")
      expect(entry.plugin).to eq("mcp:fs")
      expect(entry.metadata).to include(optional: false, side_effect: true, group: "mcp:fs")
    end

    # The server's own hint is the only thing that can say an MCP tool is a
    # read: a declared read keeps tool_concurrency instead of the serial write slot.
    it "a tool annotated readOnlyHint is not a side effect" do
      seed
      mcp_store.set_tools_cache("fs", [{ "name" => "list_files", "inputSchema" => {},
                                         "annotations" => { "readOnlyHint" => true } },
                                       { "name" => "write_file", "inputSchema" => {},
                                         "annotations" => { "readOnlyHint" => false } }])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { raise "never called" })

      expect(registry.entries.map { |e| [e.name, e.metadata[:side_effect]] })
        .to eq([["list_files", false], ["write_file", true]])
    end

    it "excludes a disabled instance's cached tools" do
      seed(enabled: false)
      mcp_store.set_tools_cache("fs", [{ "name" => "list_files", "description" => "d", "inputSchema" => {} }])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { raise "never called" })

      expect(registry.entries).to eq([])
    end

    it "building an instance from an entry never touches the client (lazy)" do
      seed
      mcp_store.set_tools_cache("fs", [{ "name" => "list_files", "description" => "d", "inputSchema" => {} }])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { raise "never called" })

      expect { registry.entries.first.factory.call }.not_to raise_error
    end
  end

  describe "#refresh" do
    it "connects, lists live, and writes McpStore#tools_cache" do
      seed
      tool = FakeRegistryTool.new("list_files", "Lists files", { "type" => "object" })
      client = FakeRegistryClient.new([tool])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { client })

      discovered = registry.refresh("fs")

      expect(discovered).to eq([{ "name" => "list_files", "description" => "Lists files", "inputSchema" => { "type" => "object" } }])
      expect(mcp_store.get_raw("fs")["tools_cache"]).to eq(discovered)
    end

    it "raises on a missing instance" do
      registry = described_class.new(mcp_store: mcp_store)
      expect { registry.refresh("nope") }.to raise_error(Insika::NotFoundError)
    end

    it "raises on a disabled instance" do
      seed(enabled: false)
      registry = described_class.new(mcp_store: mcp_store)
      expect { registry.refresh("fs") }.to raise_error(Insika::ValidationError, /disabled/)
    end

    it "rebuilds the client every call, even one that's still alive? — an edited command/env " \
       "must take effect without a process restart (grafana-stg gotcha)" do
      seed
      old_tool = FakeRegistryTool.new("old_tool", "d", {})
      new_tool = FakeRegistryTool.new("new_tool", "d", {})
      clients = [FakeRegistryClient.new([old_tool]), FakeRegistryClient.new([new_tool])]
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { clients.shift })

      first = registry.refresh("fs")
      second = registry.refresh("fs")

      expect(first.map { |t| t["name"] }).to eq(["old_tool"])
      expect(second.map { |t| t["name"] }).to eq(["new_tool"])
    end
  end

  describe "live execution" do
    it "a successful call returns the gem's own (already unwrapped) result" do
      seed
      tool = FakeRegistryTool.new("list_files", "d", {})
      client = FakeRegistryClient.new([tool])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { client })
      registry.refresh("fs")

      instance = registry.entries.first.factory.call
      expect(instance.call({ "path" => "/tmp" })).to eq(echoed: { path: "/tmp" })
    end

    it "a client that fails to start returns {error:}, never raises (turn survives)" do
      seed
      mcp_store.set_tools_cache("fs", [{ "name" => "list_files", "description" => "d", "inputSchema" => {} }])
      client = FakeRegistryClient.new([], "connection refused")
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { client })

      instance = registry.entries.first.factory.call
      expect { instance.call({}) }.not_to raise_error
      expect(instance.call({})).to eq(error: "MCP instance 'fs' tool 'list_files' failed: connection refused")
    end

    it "a tool that raises during execute returns {error:}, never raises" do
      seed
      tool = FakeRegistryTool.new("list_files", "d", {}, :boom)
      client = FakeRegistryClient.new([tool])
      registry = described_class.new(mcp_store: mcp_store, client_factory: ->(_r) { client })
      registry.refresh("fs")

      instance = registry.entries.first.factory.call
      expect(instance.call({})).to eq(error: "MCP instance 'fs' tool 'list_files' failed: connection reset")
    end

    it "the client is memoized: one factory call serves every tool call for that instance" do
      seed
      tool = FakeRegistryTool.new("list_files", "d", {})
      calls = 0
      client_factory = lambda do |_record|
        calls += 1
        FakeRegistryClient.new([tool])
      end
      registry = described_class.new(mcp_store: mcp_store, client_factory: client_factory)
      registry.refresh("fs")
      instance = registry.entries.first.factory.call
      3.times { instance.call({}) }

      expect(calls).to eq(1)
    end
  end

  # WHAT THE DEPLOYMENT TRUSTS EACH TOOL WITH, stored beside the instance and handed
  # to the tool the registry builds. Refused at ingestion, kept across an edit that
  # does not mention it — the same rule env and headers already follow.
  describe "per-tool overrides" do
    let(:store) { Insika::McpStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

    it "stores an evidence spec and a provenance requirement" do
      store.upsert(name: "s", transport: "http", url: "https://x/mcp",
                   tools: { "search_products" => { evidence: { kind: "products", items: "products",
                                                               id: "product_id", line: "name" } },
                            "add_to_cart" => { requires_evidence: ["product_id"] } })

      over = store.get_raw("s")["tool_overrides"]
      expect(over["search_products"]["evidence"]).to eq("kind" => "products", "items" => "products",
                                                        "attachments" => "attachments",
                                                        "id" => "product_id", "line" => "name")
      expect(over["add_to_cart"]).to eq("requires_evidence" => ["product_id"])
    end

    it "an edit that does not mention them keeps them" do
      store.upsert(name: "s", transport: "http", url: "https://x/mcp",
                   tools: { "add_to_cart" => { requires_evidence: ["product_id"] } })
      store.upsert(name: "s", transport: "http", url: "https://y/mcp")

      expect(store.get_raw("s")["tool_overrides"]["add_to_cart"]).to eq("requires_evidence" => ["product_id"])
    end

    it "refuses an unknown key and a malformed evidence spec at ingestion" do
      expect do
        store.upsert(name: "s", transport: "http", url: "https://x/mcp", tools: { "t" => { evidences: {} } })
      end.to raise_error(Insika::ValidationError, /unknown key/)
      expect do
        store.upsert(name: "s", transport: "http", url: "https://x/mcp",
                     tools: { "t" => { evidence: { items: "products" } } })
      end.to raise_error(Insika::ValidationError, /kind is required/)
    end

    it "hands each built tool its own overrides and nothing else's" do
      store.upsert(name: "s", transport: "http", url: "https://x/mcp",
                   tools: { "add_to_cart" => { requires_evidence: ["product_id"] } })
      store.set_tools_cache("s", [
                              { "name" => "add_to_cart", "description" => "",
                                "inputSchema" => { "type" => "object",
                                                   "properties" => { "product_id" => { "type" => "string" } } } },
                              { "name" => "view_cart", "description" => "", "inputSchema" => {} }
                            ])

      registry = described_class.new(mcp_store: store)
      built = registry.entries.to_h { |e| [e.name, e.factory.call] }

      expect(built["add_to_cart"].requires_evidence).to eq("params" => ["product_id"])
      expect(built["view_cart"].requires_evidence).to be_nil
    end
  end
end
