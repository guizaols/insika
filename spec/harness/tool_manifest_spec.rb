# frozen_string_literal: true

require "spec_helper"

# Fase 7, Etapa B (task 3+4): manifesto -> Hashes de ToolDefinition. Adapters de
# envelope (raw/OpenAI/MCP), defaults inheritance, endpoint->url (R6) and resolution
# de {{secret.*}}/{{env.*}} na ingestão com o guard de vazamento (R3).
RSpec.describe Harness::ToolManifest do
  let(:env) { { "ACHEI_URL" => "http://localhost:3000" } }
  let(:secrets) { { "TOKEN" => "s3cr3t" } }

  def manifest(defaults: {}, tools: [], version: 1)
    described_class.from_h("version" => version, "defaults" => defaults, "tools" => tools)
  end

  def defn(manifest_obj, secrets: {}, env: {})
    manifest_obj.tool_definitions(secrets: secrets, env: env)
  end

  # defaults típicos do achei (base_url por env, auth por secret, ctx por turno).
  def achei_defaults
    { "base_url" => "{{env.ACHEI_URL}}",
      "path_template" => "/api/internal/agent_tools/{endpoint}",
      "method" => "POST",
      "headers" => { "X-Chat-Id" => "{{ctx.chat_id}}",
                     "Authorization" => "Bearer {{secret.TOKEN}}",
                     "Content-Type" => "application/json" },
      "secret_headers" => ["Authorization"],
      "response" => { "extract" => "body_raw" } }
  end

  describe ".from_h" do
    it "tolera chaves symbol e string; version default = 1" do
      m = described_class.from_h(defaults: {}, tools: [{ name: "x" }])
      expect(m.version).to eq(1)
      expect(m.tools.first["name"] || m.tools.first[:name]).to eq("x")
    end

    it "rejeita defaults/tools do tipo errado (erro estrutural)" do
      expect { described_class.from_h("defaults" => []) }.to raise_error(Harness::ValidationError, /defaults/)
      expect { described_class.from_h("tools" => {}) }.to raise_error(Harness::ValidationError, /tools/)
    end
  end

  describe "adapters de envelope (D3)" do
    let(:params) { { "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"] } }

    it "cru: parameters é JSON Schema" do
      m = manifest(tools: [{ "name" => "raw", "url" => "https://api.test/x", "parameters" => params }])
      d = defn(m).first
      expect(d["name"]).to eq("raw")
      expect(d["parameters"]).to eq(params)
    end

    it "OpenAI/Anthropic: function{name,description,parameters}" do
      m = manifest(tools: [{ "url" => "https://api.test/x",
                             "function" => { "name" => "fn", "description" => "d", "parameters" => params } }])
      d = defn(m).first
      expect(d["name"]).to eq("fn")
      expect(d["description"]).to eq("d")
      expect(d["parameters"]).to eq(params)
    end

    it "MCP: inputSchema (name/description no topo)" do
      m = manifest(tools: [{ "name" => "mcp", "description" => "d", "url" => "https://api.test/x",
                             "inputSchema" => params }])
      d = defn(m).first
      expect(d["name"]).to eq("mcp")
      expect(d["parameters"]).to eq(params)
    end
  end

  describe "herança de defaults + endpoint->url (R6)" do
    it "monta url = base_url + path_template({endpoint}) e herda method/headers/response" do
      m = manifest(defaults: achei_defaults,
                   tools: [{ "name" => "search_products", "endpoint" => "search_faqs", "description" => "b",
                             "parameters" => { "type" => "object", "properties" => {}, "required" => [] } }])
      d = defn(m, secrets: secrets, env: env).first
      # endpoint (slug) != name -> remap por DADO, nunca inferido do name (R6)
      expect(d["request"]["url"]).to eq("http://localhost:3000/api/internal/agent_tools/search_faqs")
      expect(d["request"]["method"]).to eq("POST")
      expect(d["request"]["headers"]).to include("Content-Type" => "application/json")
      expect(d["response"]).to eq("extract" => "body_raw")
    end

    it "url explícita da tool vence base_url/path_template" do
      m = manifest(defaults: achei_defaults,
                   tools: [{ "name" => "ping", "url" => "https://api.test/ping", "method" => "GET",
                             "parameters" => { "type" => "object", "properties" => {}, "required" => [] } }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["url"]).to eq("https://api.test/ping")
    end

    it "requires endpoint when there is no url (never infers from name — R6)" do
      m = manifest(defaults: achei_defaults, tools: [{ "name" => "sem_endpoint" }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Harness::ValidationError, /endpoint/)
    end

    it "side_effect derives from method when omitted (POST=true, GET=false)" do
      m = manifest(defaults: achei_defaults,
                   tools: [{ "name" => "a", "endpoint" => "a", "description" => "d" },
                           { "name" => "b", "url" => "https://api.test/b", "method" => "GET", "description" => "d" }])
      a, b = defn(m, secrets: secrets, env: env)
      expect(Harness::ToolDefinition.from_h(a).side_effect).to be(true)
      expect(Harness::ToolDefinition.from_h(b).side_effect).to be(false)
    end
  end

  describe "resolution of {{env.*}} / {{secret.*}} (task 4)" do
    it "resolve env na url e secret no header (com prefixo 'Bearer ')" do
      m = manifest(defaults: achei_defaults,
                   tools: [{ "name" => "t", "endpoint" => "t" }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["url"]).to start_with("http://localhost:3000")
      expect(d["request"]["headers"]["Authorization"]).to eq("Bearer s3cr3t")
      expect(d["secret_headers"]).to eq(["Authorization"])
    end

    it "deixa {{param}} e {{ctx.*}} INTACTOS (resolvem no turno)" do
      m = manifest(defaults: achei_defaults,
                   tools: [{ "name" => "t", "endpoint" => "t", "body" => "{\"q\":\"{{q}}\"}",
                             "parameters" => { "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"] } }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["headers"]["X-Chat-Id"]).to eq("{{ctx.chat_id}}")
      expect(d["request"]["body"]).to eq("{\"q\":\"{{q}}\"}")
    end

    it "clear error when env/secret is not configured in the deployment" do
      m = manifest(defaults: achei_defaults, tools: [{ "name" => "t", "endpoint" => "t" }])
      expect { defn(m, secrets: {}, env: env) }.to raise_error(Harness::ValidationError, /secret 'TOKEN'/)
      expect { defn(m, secrets: secrets, env: {}) }.to raise_error(Harness::ValidationError, /env 'ACHEI_URL'/)
    end
  end

  describe "group/tags (Etapa C: D4/F5)" do
    it "propaga group/tags da tool" do
      m = manifest(tools: [{ "name" => "t", "url" => "https://api.test/x", "group" => "b2b", "tags" => ["catalog"] }])
      d = defn(m).first
      expect(d["group"]).to eq("b2b")
      expect(d["tags"]).to eq(["catalog"])
    end

    it "herda group do defaults; tags em UNIÃO (defaults ∪ tool)" do
      m = manifest(defaults: { "group" => "b2b", "tags" => ["internal"] },
                   tools: [{ "name" => "a", "url" => "https://api.test/a" },
                           { "name" => "b", "url" => "https://api.test/b", "group" => "beauty", "tags" => ["loja"] }])
      a, b = defn(m)
      expect(a["group"]).to eq("b2b")            # herdou o default
      expect(a["tags"]).to eq(["internal"])
      expect(b["group"]).to eq("beauty")         # tool vence o default
      expect(b["tags"]).to contain_exactly("internal", "loja") # união
    end
  end

  describe "segurança de secret (R3 + guard de vazamento)" do
    it "recusa secret_header com valor LITERAL (sem {{secret.*}}) — R3" do
      d = achei_defaults.merge("headers" => achei_defaults["headers"].merge("Authorization" => "Bearer HARDCODED"))
      m = manifest(defaults: d, tools: [{ "name" => "t", "endpoint" => "t" }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Harness::ValidationError, /never a literal.*R3/)
    end

    it "recusa {{secret.*}} FORA de um secret_header (leak sem masking)" do
      m = manifest(defaults: { "base_url" => "https://api.test", "path_template" => "/{endpoint}", "method" => "GET" },
                   tools: [{ "name" => "t", "endpoint" => "t",
                             "headers" => { "X-Leak" => "{{secret.TOKEN}}" } }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Harness::ValidationError, /secret_headers.*leak/)
    end
  end
end
