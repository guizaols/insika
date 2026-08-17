# frozen_string_literal: true

require "spec_helper"

# (+4): manifest -> ToolDefinition Hashes. Envelope
# adapters (raw/OpenAI/MCP), defaults inheritance, endpoint->url (R6) and resolution
# of {{secret.*}}/{{env.*}} at ingestion with the leak guard (R3).
RSpec.describe Insika::ToolManifest do
  let(:env) { { "CONSUMER_URL" => "http://localhost:3000" } }
  let(:secrets) { { "TOKEN" => "s3cr3t" } }

  def manifest(defaults: {}, tools: [], version: 1)
    described_class.from_h("version" => version, "defaults" => defaults, "tools" => tools)
  end

  def defn(manifest_obj, secrets: {}, env: {})
    manifest_obj.tool_definitions(secrets: secrets, env: env)
  end

  # typical consumer defaults (base_url from env, auth from secret, ctx per turn).
  def consumer_defaults
    { "base_url" => "{{env.CONSUMER_URL}}",
      "path_template" => "/api/internal/agent_tools/{endpoint}",
      "method" => "POST",
      "headers" => { "X-Chat-Id" => "{{ctx.chat_id}}",
                     "Authorization" => "Bearer {{secret.TOKEN}}",
                     "Content-Type" => "application/json" },
      "secret_headers" => ["Authorization"],
      "response" => { "extract" => "body_raw" } }
  end

  describe ".from_h" do
    it "tolerates symbol and string keys; version default = 1" do
      m = described_class.from_h(defaults: {}, tools: [{ name: "x" }])
      expect(m.version).to eq(1)
      expect(m.tools.first["name"] || m.tools.first[:name]).to eq("x")
    end

    it "rejects defaults/tools of the wrong type (structural error)" do
      expect { described_class.from_h("defaults" => []) }.to raise_error(Insika::ValidationError, /defaults/)
      expect { described_class.from_h("tools" => {}) }.to raise_error(Insika::ValidationError, /tools/)
    end
  end

  describe "envelope adapters" do
    let(:params) { { "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"] } }

    it "raw: parameters is a JSON Schema" do
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

    it "MCP: inputSchema (name/description at the top)" do
      m = manifest(tools: [{ "name" => "mcp", "description" => "d", "url" => "https://api.test/x",
                             "inputSchema" => params }])
      d = defn(m).first
      expect(d["name"]).to eq("mcp")
      expect(d["parameters"]).to eq(params)
    end
  end

  describe "defaults inheritance + endpoint->url (R6)" do
    it "builds url = base_url + path_template({endpoint}) and inherits method/headers/response" do
      m = manifest(defaults: consumer_defaults,
                   tools: [{ "name" => "search_products", "endpoint" => "search_faqs", "description" => "b",
                             "parameters" => { "type" => "object", "properties" => {}, "required" => [] } }])
      d = defn(m, secrets: secrets, env: env).first
      # endpoint (slug) != name -> remap by DATA, never inferred from the name (R6)
      expect(d["request"]["url"]).to eq("http://localhost:3000/api/internal/agent_tools/search_faqs")
      expect(d["request"]["method"]).to eq("POST")
      expect(d["request"]["headers"]).to include("Content-Type" => "application/json")
      expect(d["response"]).to eq("extract" => "body_raw")
    end

    it "the tool's explicit url wins over base_url/path_template" do
      m = manifest(defaults: consumer_defaults,
                   tools: [{ "name" => "ping", "url" => "https://api.test/ping", "method" => "GET",
                             "parameters" => { "type" => "object", "properties" => {}, "required" => [] } }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["url"]).to eq("https://api.test/ping")
    end

    it "requires endpoint when there is no url (never infers from name — R6)" do
      m = manifest(defaults: consumer_defaults, tools: [{ "name" => "sem_endpoint" }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Insika::ValidationError, /endpoint/)
    end

    it "side_effect derives from method when omitted (POST=true, GET=false)" do
      m = manifest(defaults: consumer_defaults,
                   tools: [{ "name" => "a", "endpoint" => "a", "description" => "d" },
                           { "name" => "b", "url" => "https://api.test/b", "method" => "GET", "description" => "d" }])
      a, b = defn(m, secrets: secrets, env: env)
      expect(Insika::ToolDefinition.from_h(a).side_effect).to be(true)
      expect(Insika::ToolDefinition.from_h(b).side_effect).to be(false)
    end
  end

  describe "resolution of {{env.*}} / {{secret.*}}" do
    it "resolves env in the url and secret in the header (with the 'Bearer ' prefix)" do
      m = manifest(defaults: consumer_defaults,
                   tools: [{ "name" => "t", "endpoint" => "t" }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["url"]).to start_with("http://localhost:3000")
      expect(d["request"]["headers"]["Authorization"]).to eq("Bearer s3cr3t")
      expect(d["secret_headers"]).to eq(["Authorization"])
    end

    it "leaves {{param}} and {{ctx.*}} INTACT (they resolve at the turn)" do
      m = manifest(defaults: consumer_defaults,
                   tools: [{ "name" => "t", "endpoint" => "t", "body" => "{\"q\":\"{{q}}\"}",
                             "parameters" => { "type" => "object", "properties" => { "q" => { "type" => "string" } }, "required" => ["q"] } }])
      d = defn(m, secrets: secrets, env: env).first
      expect(d["request"]["headers"]["X-Chat-Id"]).to eq("{{ctx.chat_id}}")
      expect(d["request"]["body"]).to eq("{\"q\":\"{{q}}\"}")
    end

    it "clear error when env/secret is not configured in the deployment" do
      m = manifest(defaults: consumer_defaults, tools: [{ "name" => "t", "endpoint" => "t" }])
      expect { defn(m, secrets: {}, env: env) }.to raise_error(Insika::ValidationError, /secret 'TOKEN'/)
      expect { defn(m, secrets: secrets, env: {}) }.to raise_error(Insika::ValidationError, /env 'CONSUMER_URL'/)
    end
  end

  describe "group/tags" do
    it "propagates the tool's group/tags" do
      m = manifest(tools: [{ "name" => "t", "url" => "https://api.test/x", "group" => "b2b", "tags" => ["catalog"] }])
      d = defn(m).first
      expect(d["group"]).to eq("b2b")
      expect(d["tags"]).to eq(["catalog"])
    end

    it "inherits group from defaults; tags in UNION (defaults ∪ tool)" do
      m = manifest(defaults: { "group" => "b2b", "tags" => ["internal"] },
                   tools: [{ "name" => "a", "url" => "https://api.test/a" },
                           { "name" => "b", "url" => "https://api.test/b", "group" => "beauty", "tags" => ["loja"] }])
      a, b = defn(m)
      expect(a["group"]).to eq("b2b")            # inherited the default
      expect(a["tags"]).to eq(["internal"])
      expect(b["group"]).to eq("beauty")         # tool wins over the default
      expect(b["tags"]).to contain_exactly("internal", "loja") # union
    end
  end

  it "carries halt_when through, and never inherits it from defaults" do
    halt = { "json_path" => "tool_result.status", "equals" => ["SUBSCRIBED"] }
    m = manifest(defaults: { "halt_when" => halt },
                 tools: [{ "name" => "a", "url" => "https://api.test/a" },
                         { "name" => "b", "url" => "https://api.test/b", "halt_when" => halt }])
    a, b = defn(m)
    expect(a).not_to have_key("halt_when") # a sibling's ending is not a shared default
    expect(b["halt_when"]).to eq(halt)
  end

  it "carries the evidence declaration through (RFC-0029), absent when undeclared" do
    m = manifest(tools: [{ "name" => "a", "url" => "https://api.test/a" },
                         { "name" => "b", "url" => "https://api.test/b",
                           "evidence" => { "kind" => "products", "items" => "results" } }])
    a, b = defn(m)
    expect(a).not_to have_key("evidence")
    expect(b["evidence"]).to eq("kind" => "products", "items" => "results",
                                "attachments" => "attachments")
  end

  it "refuses a malformed evidence declaration at ingestion (isolable per tool)" do
    m = manifest(tools: [{ "name" => "b", "url" => "https://api.test/b",
                           "evidence" => { "items" => "results" } }])
    expect { defn(m) }.to raise_error(Insika::ValidationError, /kind/)
  end

  describe "secret safety (R3 + leak guard)" do
    it "rejects a secret_header with a LITERAL value (no {{secret.*}}) — R3" do
      d = consumer_defaults.merge("headers" => consumer_defaults["headers"].merge("Authorization" => "Bearer HARDCODED"))
      m = manifest(defaults: d, tools: [{ "name" => "t", "endpoint" => "t" }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Insika::ValidationError, /never a literal.*R3/)
    end

    it "rejects {{secret.*}} OUTSIDE a secret_header (leak without masking)" do
      m = manifest(defaults: { "base_url" => "https://api.test", "path_template" => "/{endpoint}", "method" => "GET" },
                   tools: [{ "name" => "t", "endpoint" => "t",
                             "headers" => { "X-Leak" => "{{secret.TOKEN}}" } }])
      expect { defn(m, secrets: secrets, env: env) }.to raise_error(Insika::ValidationError, /secret_headers.*leak/)
    end
  end
end
