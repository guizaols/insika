# frozen_string_literal: true

require "spec_helper"

# Fase 7, Etapa B (task 5): Command :import_tools — upsert em LOTE de data-tools
# por manifesto, reload hot, relatório por-tool e falha parcial isolada (R4).
RSpec.describe Harness::Commands::ImportTools do
  CodeToolStub2 = Struct.new(:name, :description)

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  let(:base) do
    r = Harness::ToolRegistry.new
    r.register("menu", plugin: "code") { CodeToolStub2.new("menu", "cardápio") }
    r
  end
  let(:store) { Harness::ToolStore.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }
  let(:overlay) { Harness::OverlayToolRegistry.new(base: base, tool_store: store, http: Object.new) }
  let(:catalog) { Harness::ToolCatalog.new(tool_registry: overlay) }

  let(:secrets) { { "TOKEN" => "s3cr3t" } }
  let(:env) { { "CONSUMER_URL" => "http://localhost:3000" } }

  let(:command) do
    described_class.new(tool_store: store, registry: overlay, tool_catalog: catalog,
                        event_stream: event_stream, secrets: secrets, env: env)
  end

  def run(manifest) = command.call(Harness::Command.build(:import_tools, manifest, transport: :test))

  def consumer_manifest(tools)
    { "version" => 1,
      "defaults" => { "base_url" => "{{env.CONSUMER_URL}}", "path_template" => "/api/internal/agent_tools/{endpoint}",
                      "method" => "POST",
                      "headers" => { "Authorization" => "Bearer {{secret.TOKEN}}", "Content-Type" => "application/json" },
                      "secret_headers" => ["Authorization"], "response" => { "extract" => "body_raw" } },
      "tools" => tools }
  end

  def tool(name, **over) = { "name" => name, "endpoint" => name, "description" => "d" }.merge(over)

  it "upsert em lote, reload hot (overlay+catálogo) e relatório por-tool" do
    report = run(consumer_manifest([tool("search_products"), tool("search_faq", "endpoint" => "search_faqs")]))

    expect(report[:version]).to eq(1)
    expect(report[:created]).to contain_exactly("search_products", "search_faq")
    expect(report[:updated]).to be_empty
    expect(report[:errors]).to be_empty
    expect(overlay.names).to include("search_products", "search_faq") # overlay recarregado (hot)
    expect(catalog.all.map(&:name)).to include("search_products")     # catálogo recarregado
  end

  it "emite :tools_imported só com CONTAGENS (0 vazamento de secret)" do
    run(consumer_manifest([tool("t")]))
    ev = events.last
    expect(ev.type).to eq(:tools_imported)
    expect(ev.data).to eq(created: 1, updated: 0, errors: 0)
    expect(ev.to_h.inspect).not_to include("s3cr3t")
  end

  it "idempotente: re-importar reconcilia (updated, não created); secret preservado" do
    run(consumer_manifest([tool("t")]))
    report = run(consumer_manifest([tool("t", "description" => "v2")]))

    expect(report[:created]).to be_empty
    expect(report[:updated]).to eq(["t"])
    expect(store.get_raw("t")["description"]).to eq("v2")
    expect(store.get_raw("t")["request"]["headers"]["Authorization"]).to eq("Bearer s3cr3t")
  end

  it "não vaza secret: o store mascara o header credencial" do
    run(consumer_manifest([tool("t")]))
    masked = store.get("t") # visão de UI
    expect(masked["request"]["headers"]["Authorization"]).to eq(Harness::SecretMasking::SENTINEL)
  end

  describe "falha parcial isolada (R4)" do
    it "uma tool malformada não derruba as demais — vira entry em errors[]" do
      report = run(consumer_manifest([
                                    tool("boa"),
                                    tool("ruim", "endpoint" => nil, "url" => nil), # sem endpoint nem url
                                    tool("outra")
                                  ]))

      expect(report[:created]).to contain_exactly("boa", "outra")
      expect(report[:errors].size).to eq(1)
      expect(report[:errors].first[:tool]).to eq("ruim")
      expect(report[:errors].first[:error]).to match(/endpoint/)
      expect(overlay.names).to include("boa", "outra")
    end

    it "colisão com tool de código vira erro isolado (R3), não derruba o lote" do
      report = run(consumer_manifest([tool("menu"), tool("ok")]))
      expect(report[:errors].map { |e| e[:tool] }).to eq(["menu"])
      expect(report[:errors].first[:error]).to match(/tool de código/)
      expect(report[:created]).to eq(["ok"])
    end

    it "secret não configurado no deployment vira erro isolado por-tool" do
      cmd = described_class.new(tool_store: store, registry: overlay, tool_catalog: catalog,
                                event_stream: event_stream, secrets: {}, env: env)
      report = cmd.call(Harness::Command.build(:import_tools, consumer_manifest([tool("t")]), transport: :test))
      expect(report[:created]).to be_empty
      expect(report[:errors].first[:error]).to match(/secret 'TOKEN'/)
    end

    it "lote 100% com erro NÃO recarrega o overlay (nada a valer)" do
      expect(overlay).not_to receive(:reload)
      report = run(consumer_manifest([tool("menu")])) # só a colisão
      expect(report[:errors].size).to eq(1)
    end
  end

  it "erro ESTRUTURAL do manifesto propaga (não é per-tool)" do
    expect { run("defaults" => [], "tools" => []) }.to raise_error(Harness::ValidationError, /defaults/)
  end
end
