# frozen_string_literal: true

require "spec_helper"

# data-defined tool authoring commands (write/delete/restore).
RSpec.describe "data-tool commands" do
  CodeToolStub = Struct.new(:name, :description)

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  let(:base) do
    r = Insika::ToolRegistry.new
    r.register("menu", plugin: "code") { CodeToolStub.new("menu", "cardápio") }
    r
  end
  let(:store) { Insika::ToolStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:overlay) { Insika::OverlayToolRegistry.new(base: base, tool_store: store, http: Object.new) }
  let(:catalog) { Insika::ToolCatalog.new(tool_registry: overlay) }

  let(:deps) { { tool_store: store, registry: overlay, tool_catalog: catalog, event_stream: event_stream } }

  def dispatch(klass, payload)
    klass.new(**deps).call(Insika::Command.build(payload[:type] || :x, payload, transport: :test, tenant: nil))
  end

  def cep_payload(**over)
    { name: "cep", description: "Consulta CEP",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" } }.merge(over)
  end

  describe Insika::Commands::WriteDataTool do
    it "writes, reloads overlay+catalog (hot) and emits :data_tool_written" do
      res = dispatch(described_class, cep_payload)
      expect(res[:name]).to eq("cep")
      expect(overlay.names).to include("cep")          # overlay reloaded
      expect(catalog.all.map(&:name)).to include("cep") # catalog reloaded
      expect(events.last.type).to eq(:data_tool_written)
      expect(events.last.data).to eq(name: "cep")
    end

    it "refuses a name that collides with a code tool (R3)" do
      expect { dispatch(described_class, cep_payload(name: "menu")) }
        .to raise_error(Insika::ValidationError, /code tool/)
    end

    it "propagates the definition validation (delegated to the store/ToolDefinition)" do
      expect { dispatch(described_class, cep_payload(request: { method: "GET", url: "" })) }
        .to raise_error(Insika::ValidationError, /url is required/)
    end

    it "does not leak the secret in the return value or the event" do
      secret = { name: "api", description: "api", parameters: [],
                 request: { method: "POST", url: "https://api.test/x",
                            headers: { "Authorization" => "Bearer TOPSECRET" } },
                 secret_headers: ["Authorization"] }
      res = dispatch(described_class, secret)
      dump = [res, events.last.data].inspect
      expect(dump).not_to include("TOPSECRET")
      expect(res[:definition]["request"]["headers"]["Authorization"]).to eq(Insika::SecretMasking::SENTINEL)
    end
  end

  describe Insika::Commands::DeleteDataTool do
    it "removes, reloads and emits :data_tool_deleted" do
      dispatch(Insika::Commands::WriteDataTool, cep_payload)
      res = dispatch(described_class, { name: "cep" })
      expect(res).to eq(name: "cep")
      expect(overlay.names).not_to include("cep")
      expect(catalog.all.map(&:name)).not_to include("cep")
      expect(events.last.type).to eq(:data_tool_deleted)
    end

    it "404 if it did not exist" do
      expect { dispatch(described_class, { name: "fantasma" }) }
        .to raise_error(Insika::NotFoundError)
    end
  end

  describe Insika::Commands::RestoreDataTool do
    it "restores an old version, reloads and emits :data_tool_restored" do
      dispatch(Insika::Commands::WriteDataTool, cep_payload(description: "v1"))
      dispatch(Insika::Commands::WriteDataTool, cep_payload(description: "v2"))
      res = dispatch(described_class, { name: "cep", index: 0 })
      expect(res[:name]).to eq("cep")
      expect(store.get("cep")["description"]).to eq("v1")
      expect(events.last.type).to eq(:data_tool_restored)
    end
  end
end
