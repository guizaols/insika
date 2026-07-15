# frozen_string_literal: true

require "spec_helper"

# Fase 5 Etapa B: Commands de autoria de tool por dados (write/delete/restore).
RSpec.describe "data-tool commands" do
  CodeToolStub = Struct.new(:name, :description)

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  let(:base) do
    r = Harness::ToolRegistry.new
    r.register("menu", plugin: "code") { CodeToolStub.new("menu", "cardápio") }
    r
  end
  let(:store) { Harness::ToolStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:overlay) { Harness::OverlayToolRegistry.new(base: base, tool_store: store, http: Object.new) }
  let(:catalog) { Harness::ToolCatalog.new(tool_registry: overlay) }

  let(:deps) { { tool_store: store, registry: overlay, tool_catalog: catalog, event_stream: event_stream } }

  def dispatch(klass, payload)
    klass.new(**deps).call(Harness::Command.build(payload[:type] || :x, payload, transport: :test, tenant: nil))
  end

  def cep_payload(**over)
    { name: "cep", description: "Consulta CEP",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" } }.merge(over)
  end

  describe Harness::Commands::WriteDataTool do
    it "grava, recarrega overlay+catálogo (hot) e emite :data_tool_written" do
      res = dispatch(described_class, cep_payload)
      expect(res[:name]).to eq("cep")
      expect(overlay.names).to include("cep")          # overlay recarregado
      expect(catalog.all.map(&:name)).to include("cep") # catálogo recarregado
      expect(events.last.type).to eq(:data_tool_written)
      expect(events.last.data).to eq(name: "cep")
    end

    it "recusa nome que colide com tool de código (R3)" do
      expect { dispatch(described_class, cep_payload(name: "menu")) }
        .to raise_error(Harness::ValidationError, /tool de código/)
    end

    it "propaga a validação da definição (delegada ao store/ToolDefinition)" do
      expect { dispatch(described_class, cep_payload(request: { method: "GET", url: "" })) }
        .to raise_error(Harness::ValidationError, /url é obrigatória/)
    end

    it "não vaza segredo no retorno nem no evento" do
      secret = { name: "api", description: "api", parameters: [],
                 request: { method: "POST", url: "https://api.test/x",
                            headers: { "Authorization" => "Bearer TOPSECRET" } },
                 secret_headers: ["Authorization"] }
      res = dispatch(described_class, secret)
      dump = [res, events.last.data].inspect
      expect(dump).not_to include("TOPSECRET")
      expect(res[:definition]["request"]["headers"]["Authorization"]).to eq(Harness::SecretMasking::SENTINEL)
    end
  end

  describe Harness::Commands::DeleteDataTool do
    it "remove, recarrega e emite :data_tool_deleted" do
      dispatch(Harness::Commands::WriteDataTool, cep_payload)
      res = dispatch(described_class, { name: "cep" })
      expect(res).to eq(name: "cep")
      expect(overlay.names).not_to include("cep")
      expect(catalog.all.map(&:name)).not_to include("cep")
      expect(events.last.type).to eq(:data_tool_deleted)
    end

    it "404 se não existia" do
      expect { dispatch(described_class, { name: "fantasma" }) }
        .to raise_error(Harness::NotFoundError)
    end
  end

  describe Harness::Commands::RestoreDataTool do
    it "restaura versão antiga, recarrega e emite :data_tool_restored" do
      dispatch(Harness::Commands::WriteDataTool, cep_payload(description: "v1"))
      dispatch(Harness::Commands::WriteDataTool, cep_payload(description: "v2"))
      res = dispatch(described_class, { name: "cep", index: 0 })
      expect(res[:name]).to eq("cep")
      expect(store.get("cep")["description"]).to eq("v1")
      expect(events.last.type).to eq(:data_tool_restored)
    end
  end
end
