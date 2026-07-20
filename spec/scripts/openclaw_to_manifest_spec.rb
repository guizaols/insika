# frozen_string_literal: true

require "spec_helper"
require_relative "../../scripts/internal/openclaw_to_manifest"

# Correctness proof of the one-off converter (Phase 7, Step D / task 7). HERMETIC:
# roda sobre um fixture pequeno em spec/fixtures/openclaw_tools (3 tools
# registradas + 1 dormente), NUNCA sobre a fonte externa. O contrato central:
# o manifesto emitido tem que atravessar ToolManifest -> ToolDefinition sem erro.
RSpec.describe OpenclawToManifest do
  let(:plugin_dir) { File.expand_path("../fixtures/openclaw_tools", __dir__) }
  let(:manifest) { described_class.build_manifest(plugin_dir) }
  let(:tools) { manifest["tools"] }
  let(:by_name) { tools.to_h { |t| [t["name"], t] } }

  it "emite só as tools REGISTRADAS no index.ts (ignora a dormente)" do
    expect(by_name.keys).to contain_exactly("search_products", "search_faq", "send_finalize_button")
    expect(by_name).not_to have_key("dormant_tool")
  end

  describe "o manifesto emitido" do
    # O teste-âncora: passar por ToolManifest.tool_definitions + ToolDefinition.from_h
    # (the engine's real validation) without raising. secrets/env injected off-disk.
    let(:definitions) do
      Harness::ToolManifest.from_h(manifest).tool_definitions(
        secrets: { "BIA_INTERNAL_API_TOKEN" => "x" },
        env: { "ACHEI_INTERNAL_URL" => "http://localhost:3000" }
      )
    end

    it "atravessa ToolManifest sem erro" do
      expect { definitions }.not_to raise_error
      expect(definitions.size).to eq(3)
    end

    it "each definition validates as a ToolDefinition" do
      definitions.each do |defn|
        expect { Harness::ToolDefinition.from_h(defn) }.not_to raise_error
      end
    end

    it "resolve secret/env do binding (Authorization -> Bearer; url do env)" do
      defn = definitions.find { |d| d["name"] == "search_products" }
      expect(defn.dig("request", "headers", "Authorization")).to eq("Bearer x")
      expect(defn.dig("request", "url")).to eq("http://localhost:3000/api/internal/agent_tools/search_products")
      expect(defn["secret_headers"]).to eq(["Authorization"])
    end
  end

  describe "endpoint ≠ name (R6: slug do callAgentTool, nunca inferido do name)" do
    it "preserva o slug divergente" do
      expect(by_name["search_faq"]["endpoint"]).to eq("search_faqs")
      expect(by_name["send_finalize_button"]["endpoint"]).to eq("finalize_button")
    end

    it "keeps the slug equal to the name when they match" do
      expect(by_name["search_products"]["endpoint"]).to eq("search_products")
    end
  end

  describe "grupo como DADO (Etapa C)" do
    it "derives the group by name convention" do
      expect(by_name["search_products"]["group"]).to eq("default")
      expect(by_name["search_faq"]["group"]).to eq("core")
      expect(by_name["send_finalize_button"]["group"]).to eq("default")
    end
  end

  describe "side_effect (reads do not mutate)" do
    it "search_* é read; o resto muta" do
      expect(by_name["search_products"]["side_effect"]).to be(false)
      expect(by_name["search_faq"]["side_effect"]).to be(false)
      expect(by_name["send_finalize_button"]["side_effect"]).to be(true)
    end
  end

  describe "param aninhado -> JSON Schema aninhado de verdade" do
    let(:params) { by_name["search_products"]["parameters"] }

    it "root is an object with required derived from (non-)Optional" do
      expect(params["type"]).to eq("object")
      # query_filter_pairs is NOT Optional -> required; catalog_mode is Optional -> not.
      expect(params["required"]).to contain_exactly("query_filter_pairs")
    end

    it "query_filter_pairs é array de object (com minItems)" do
      qfp = params.dig("properties", "query_filter_pairs")
      expect(qfp["type"]).to eq("array")
      expect(qfp["minItems"]).to eq(1)
      expect(qfp.dig("items", "type")).to eq("object")
    end

    it "aninha object dentro do item do array, com required e additionalProperties" do
      item = params.dig("properties", "query_filter_pairs", "items")
      # query required; filters Optional
      expect(item["required"]).to contain_exactly("query")
      expect(item.dig("properties", "query", "type")).to eq("string")
      filters = item.dig("properties", "filters")
      expect(filters["type"]).to eq("object")
      expect(filters["additionalProperties"]).to be(true)
    end

    it "recorre em profundidade (filters.price.min/max: number; additionalProperties false)" do
      price = params.dig("properties", "query_filter_pairs", "items",
                         "properties", "filters", "properties", "price")
      expect(price["type"]).to eq("object")
      expect(price["additionalProperties"]).to be(false)
      expect(price.dig("properties", "min", "type")).to eq("number")
      expect(price.dig("properties", "max", "type")).to eq("number")
    end

    it "mapeia Type.Array(Type.String()) -> array de string" do
      color = params.dig("properties", "query_filter_pairs", "items",
                         "properties", "filters", "properties", "color")
      expect(color["type"]).to eq("array")
      expect(color.dig("items", "type")).to eq("string")
    end

    it "mapeia Type.Boolean -> boolean" do
      expect(params.dig("properties", "catalog_mode", "type")).to eq("boolean")
    end
  end

  describe "constraints de escalar (minLength/maxLength) preservadas" do
    it "send_finalize_button.message carrega min/maxLength" do
      msg = by_name["send_finalize_button"].dig("parameters", "properties", "message")
      expect(msg["type"]).to eq("string")
      expect(msg["minLength"]).to eq(5)
      expect(msg["maxLength"]).to eq(600)
    end
  end

  describe "defaults do manifesto (binding comum)" do
    it "secret é referência (never a literal — R3) e fica em secret_headers" do
      auth = manifest.dig("defaults", "headers", "Authorization")
      expect(auth).to eq("Bearer {{secret.BIA_INTERNAL_API_TOKEN}}")
      expect(manifest.dig("defaults", "secret_headers")).to eq(["Authorization"])
    end

    it "base_url vem do env e o path usa {endpoint}" do
      expect(manifest.dig("defaults", "base_url")).to eq("{{env.ACHEI_INTERNAL_URL}}")
      expect(manifest.dig("defaults", "path_template")).to eq("/api/internal/agent_tools/{endpoint}")
    end
  end

  describe "body template reencaminha os params de topo" do
    it "objeto/array vão inteiros; string entre aspas" do
      body = by_name["search_products"]["body"]
      expect(body).to include("\"query_filter_pairs\":{{query_filter_pairs}}")
      expect(body).to include("\"catalog_mode\":{{catalog_mode}}")

      faq_body = by_name["search_faq"]["body"]
      expect(faq_body).to eq('{"query":"{{query}}"}')
    end
  end
end
