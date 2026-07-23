# frozen_string_literal: true

require "spec_helper"

# Phase 7, Stage B (task 5): Command :import_tools — BATCH upsert of data-tools
# by manifest, hot reload, per-tool report and isolated partial failure (R4).
RSpec.describe Insika::Commands::ImportTools do
  CodeToolStub2 = Struct.new(:name, :description)

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  let(:base) do
    r = Insika::ToolRegistry.new
    r.register("menu", plugin: "code") { CodeToolStub2.new("menu", "cardápio") }
    r
  end
  let(:store) { Insika::ToolStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }
  let(:overlay) { Insika::OverlayToolRegistry.new(base: base, tool_store: store, http: Object.new) }
  let(:catalog) { Insika::ToolCatalog.new(tool_registry: overlay) }

  let(:secrets) { { "TOKEN" => "s3cr3t" } }
  let(:env) { { "CONSUMER_URL" => "http://localhost:3000" } }

  let(:command) do
    described_class.new(tool_store: store, registry: overlay, tool_catalog: catalog,
                        event_stream: event_stream, secrets: secrets, env: env)
  end

  def run(manifest) = command.call(Insika::Command.build(:import_tools, manifest, transport: :test))

  def consumer_manifest(tools)
    { "version" => 1,
      "defaults" => { "base_url" => "{{env.CONSUMER_URL}}", "path_template" => "/api/internal/agent_tools/{endpoint}",
                      "method" => "POST",
                      "headers" => { "Authorization" => "Bearer {{secret.TOKEN}}", "Content-Type" => "application/json" },
                      "secret_headers" => ["Authorization"], "response" => { "extract" => "body_raw" } },
      "tools" => tools }
  end

  def tool(name, **over) = { "name" => name, "endpoint" => name, "description" => "d" }.merge(over)

  it "batch upsert, hot reload (overlay+catalog) and per-tool report" do
    report = run(consumer_manifest([tool("search_products"), tool("search_faq", "endpoint" => "search_faqs")]))

    expect(report[:version]).to eq(1)
    expect(report[:created]).to contain_exactly("search_products", "search_faq")
    expect(report[:updated]).to be_empty
    expect(report[:errors]).to be_empty
    expect(overlay.names).to include("search_products", "search_faq") # overlay reloaded (hot)
    expect(catalog.all.map(&:name)).to include("search_products")     # catalog reloaded
  end

  it "emits :tools_imported with COUNTS only (0 secret leakage)" do
    run(consumer_manifest([tool("t")]))
    ev = events.last
    expect(ev.type).to eq(:tools_imported)
    expect(ev.data).to eq(created: 1, updated: 0, errors: 0)
    expect(ev.to_h.inspect).not_to include("s3cr3t")
  end

  it "idempotent: re-importing reconciles (updated, not created); secret preserved" do
    run(consumer_manifest([tool("t")]))
    report = run(consumer_manifest([tool("t", "description" => "v2")]))

    expect(report[:created]).to be_empty
    expect(report[:updated]).to eq(["t"])
    expect(store.get_raw("t")["description"]).to eq("v2")
    expect(store.get_raw("t")["request"]["headers"]["Authorization"]).to eq("Bearer s3cr3t")
  end

  it "does not leak the secret: the store masks the credential header" do
    run(consumer_manifest([tool("t")]))
    masked = store.get("t") # UI view
    expect(masked["request"]["headers"]["Authorization"]).to eq(Insika::SecretMasking::SENTINEL)
  end

  describe "isolated partial failure (R4)" do
    it "a malformed tool does not bring down the others — becomes an entry in errors[]" do
      report = run(consumer_manifest([
                                    tool("boa"),
                                    tool("ruim", "endpoint" => nil, "url" => nil), # no endpoint or url
                                    tool("outra")
                                  ]))

      expect(report[:created]).to contain_exactly("boa", "outra")
      expect(report[:errors].size).to eq(1)
      expect(report[:errors].first[:tool]).to eq("ruim")
      expect(report[:errors].first[:error]).to match(/endpoint/)
      expect(overlay.names).to include("boa", "outra")
    end

    it "collision with a code tool becomes an isolated error (R3), does not bring down the batch" do
      report = run(consumer_manifest([tool("menu"), tool("ok")]))
      expect(report[:errors].map { |e| e[:tool] }).to eq(["menu"])
      expect(report[:errors].first[:error]).to match(/code tool/)
      expect(report[:created]).to eq(["ok"])
    end

    it "a secret not configured in the deployment becomes an isolated per-tool error" do
      cmd = described_class.new(tool_store: store, registry: overlay, tool_catalog: catalog,
                                event_stream: event_stream, secrets: {}, env: env)
      report = cmd.call(Insika::Command.build(:import_tools, consumer_manifest([tool("t")]), transport: :test))
      expect(report[:created]).to be_empty
      expect(report[:errors].first[:error]).to match(/secret 'TOKEN'/)
    end

    it "a 100%-error batch does NOT reload the overlay (nothing valid)" do
      expect(overlay).not_to receive(:reload)
      report = run(consumer_manifest([tool("menu")])) # only the collision
      expect(report[:errors].size).to eq(1)
    end
  end

  it "a STRUCTURAL manifest error propagates (not per-tool)" do
    expect { run("defaults" => [], "tools" => []) }.to raise_error(Insika::ValidationError, /defaults/)
  end
end
