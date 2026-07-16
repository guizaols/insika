# frozen_string_literal: true

require "spec_helper"
require "harness/tools/data_defined_tool" # o overlay carrega lazy; explícito no teste

RSpec.describe Harness::Tools::DataDefinedTool do
  # http fake: grava a request, devolve o resultado configurado. Nome único p/ não
  # colidir com o ::FakeHttp de outros specs (constante top-level via `class`).
  class FakeDataHttp
    attr_reader :last

    def initialize(result) = (@result = result)
    def request(**req) = (@last = req; @result)
  end

  # egress permissivo (o guard real tem spec próprio; aqui não queremos DNS).
  PermissiveEgress = Class.new { def violation(*, **) = nil }.new

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  def tool(definition_attrs, result:, egress: PermissiveEgress, egress_options: {})
    d = Harness::ToolDefinition.build(**definition_attrs)
    described_class.new(definition: d, http: FakeDataHttp.new(result), egress: egress,
                        egress_options: egress_options, event_stream: event_stream)
  end

  let(:cep_def) do
    { name: "cep", description: "Consulta CEP",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" } }
  end

  it "name/description/parameters por instância; params_schema deriva" do
    t = tool(cep_def, result: { status: 200, body: "{}" })
    expect(t.name).to eq("cep")
    expect(t.description).to eq("Consulta CEP")
    expect(t.parameters.keys).to eq([:cep])
    expect(t.params_schema["properties"]).to have_key("cep")
    expect(t.params_schema["required"]).to include("cep")
  end

  # Fase 7, Etapa A — PROVA: um parâmetro ANINHADO (search_products) é exposto ao
  # modelo via params_schema (o que os providers serializam) E interpolado no body.
  describe "param aninhado (JSON Schema)" do
    let(:search_def) do
      {
        name: "search_products", description: "busca no catálogo",
        parameters: {
          "type" => "object",
          "properties" => {
            "query_filter_pairs" => {
              "type" => "array", "minItems" => 1,
              "items" => {
                "type" => "object",
                "properties" => {
                  "query" => { "type" => "string" },
                  "filters" => { "type" => "object", "additionalProperties" => true }
                },
                "required" => ["query"]
              }
            }
          },
          "required" => ["query_filter_pairs"]
        },
        request: { method: "POST", url: "https://api.test/search",
                   body: '{"pairs":{{query_filter_pairs}}}' },
        response: { extract: "body_raw" }
      }
    end

    it "expõe o schema aninhado ao modelo via params_schema" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      schema = t.params_schema
      items = schema.dig("properties", "query_filter_pairs", "items")
      expect(items["type"]).to eq("object")
      expect(items["properties"]).to have_key("query")
      expect(items.dig("properties", "filters", "type")).to eq("object")
    end

    it "interpola o valor aninhado (array de objetos) no body como JSON" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      pairs = [{ "query" => "arroz", "filters" => { "brand" => "tio" } }]
      t.execute(query_filter_pairs: pairs)
      body = t.instance_variable_get(:@http).last[:body]
      expect(JSON.parse(body)).to eq("pairs" => pairs)
    end
  end

  def last_url(t) = t.instance_variable_get(:@http).last[:url]

  it "GET + json_path: interpola a URL, extrai o caminho" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"São Paulo"}' })
    expect(t.execute(cep: "01001000")).to eq("São Paulo")
    expect(last_url(t)).to eq("https://viacep.com.br/ws/01001000/json")
  end

  it "percent-encode de valor na URL" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"x"}' })
    t.execute(cep: "a b/c")
    expect(last_url(t)).to eq("https://viacep.com.br/ws/a%20b%2Fc/json")
  end

  it "body_raw devolve o corpo cru; HTTP>=400 vira {error:}" do
    ok = tool(cep_def.merge(response: { extract: "body_raw" }), result: { status: 200, body: "PONG" })
    expect(ok.execute(cep: "1")).to eq("PONG")
    bad = tool(cep_def.merge(response: { extract: "body_raw" }), result: { status: 404, body: "nope" })
    expect(bad.execute(cep: "1")).to match(error: /HTTP 404/)
  end

  it "extract status devolve o status independente de erro" do
    t = tool(cep_def.merge(response: { extract: "status" }), result: { status: 503, body: "" })
    expect(t.execute(cep: "1")).to eq(status: 503)
  end

  it "json_path ausente / resposta não-JSON viram {error:}" do
    miss = tool(cep_def, result: { status: 200, body: '{"outro":1}' })
    expect(miss.execute(cep: "1")).to match(error: /não encontrado/)
    nojson = tool(cep_def, result: { status: 200, body: "<html>" })
    expect(nojson.execute(cep: "1")).to match(error: /não é JSON/)
  end

  it "param obrigatório ausente -> {error:} (não chama HTTP)" do
    t = tool(cep_def, result: { status: 200, body: "{}" })
    expect(t.execute).to match(error: /obrigatório.*ausente/)
  end

  it "egress bloqueado -> {error:} (não chama HTTP)" do
    blocking = Class.new { def violation(*, **) = "destino em rede privada bloqueado" }.new
    t = tool(cep_def, result: { status: 200, body: "{}" }, egress: blocking)
    expect(t.execute(cep: "1")).to match(error: /destino bloqueado/)
  end

  it "POST: interpola query, header e body com escaping JSON" do
    post_def = {
      name: "busca", description: "busca",
      parameters: [{ name: "q", type: "string" }, { name: "tok", type: "string" }],
      request: { method: "POST", url: "https://api.test/search",
                 query: { "lang" => "pt" }, headers: { "Authorization" => "Bearer {{tok}}" },
                 body: '{"q":"{{q}}"}' },
      response: { extract: "body_raw" }, secret_headers: ["Authorization"]
    }
    t = tool(post_def, result: { status: 200, body: "ok" })
    t.execute(q: 'a"b', tok: "T1")
    req = t.instance_variable_get(:@http).last
    expect(req[:method]).to eq("POST")
    expect(req[:url]).to eq("https://api.test/search?lang=pt")
    expect(req[:headers]["Authorization"]).to eq("Bearer T1")
    expect(req[:body]).to eq('{"q":"a\"b"}')            # aspas escapadas p/ JSON válido
  end

  # Fase 6/D2/G3: os ids do TURNO (não do modelo) viram X-Chat-Id/X-Store-Id/
  # X-Agent-Id — a PROVA da Etapa B (sem eles toda tool /api/internal/* dá 403).
  describe "contexto de turno {{ctx.*}}" do
    let(:internal_def) do
      { name: "cart", description: "carrinho da loja",
        parameters: [{ name: "sku", type: "string", required: true }],
        request: { method: "POST", url: "https://api.internal/agent_tools/cart",
                   headers: { "X-Chat-Id" => "{{ctx.chat_id}}", "X-Store-Id" => "{{ctx.store_id}}",
                              "X-Agent-Id" => "{{ctx.agent_id}}", "Authorization" => "Bearer S3CR3T" },
                   body: '{"sku":"{{sku}}","tenant":"{{ctx.tenant}}"}' },
        response: { extract: "status" }, secret_headers: ["Authorization"] }
    end

    def headers_of(t) = t.instance_variable_get(:@http).last[:headers]

    it "emite X-Chat-Id/X-Store-Id/X-Agent-Id a partir do contexto de turno" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { chat_id: "chat-42", store_id: "loja-7", agent_id: "bia", tenant: "chat-42" }
      t.execute(sku: "ABC")
      h = headers_of(t)
      expect(h["X-Chat-Id"]).to eq("chat-42")
      expect(h["X-Store-Id"]).to eq("loja-7")
      expect(h["X-Agent-Id"]).to eq("bia")
      expect(h["Authorization"]).to eq("Bearer S3CR3T") # segredo estático, não é ctx
      body = t.instance_variable_get(:@http).last[:body]
      expect(body).to eq('{"sku":"ABC","tenant":"chat-42"}')
    end

    it "aceita chaves string no contexto de turno (JSON round-trip)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { "chat_id" => "c1", "store_id" => "s1", "agent_id" => "a1", "tenant" => "c1" }
      t.execute(sku: "X")
      expect(headers_of(t)["X-Chat-Id"]).to eq("c1")
    end

    it "ctx ausente -> header vazio (não injeta arg do modelo com o mesmo nome)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      # sem turn_context setado (default {})
      t.execute(sku: "X")
      expect(headers_of(t)["X-Store-Id"]).to eq("")
    end

    it "o modelo NÃO controla ctx: um arg 'chat_id' do modelo é ignorado no ctx.*" do
      spoof_def = {
        name: "cart2", description: "d",
        parameters: [{ name: "chat_id", type: "string", required: true }],
        request: { method: "GET", url: "https://api.internal/x",
                   headers: { "X-Chat-Id" => "{{ctx.chat_id}}", "X-Model" => "{{chat_id}}" } },
        response: { extract: "status" }
      }
      t = tool(spoof_def, result: { status: 200, body: "" })
      t.turn_context = { chat_id: "real-chat" }
      t.execute(chat_id: "spoofed")
      h = headers_of(t)
      expect(h["X-Chat-Id"]).to eq("real-chat") # do turno
      expect(h["X-Model"]).to eq("spoofed")     # do modelo, canal separado
    end

    it "CRLF em valor de ctx é removido no header (anti-injeção)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { chat_id: "a\r\nX-Evil: 1", store_id: "", agent_id: "", tenant: "" }
      t.execute(sku: "X")
      expect(headers_of(t)["X-Chat-Id"]).to eq("aX-Evil: 1")
    end
  end

  it "emite :data_tool_call com status, sem vazar corpo/segredo" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"X"}' })
    t.execute(cep: "1")
    ev = events.last
    expect(ev.type).to eq(:data_tool_call)
    expect(ev.data).to eq(tool: "cep", status: 200)
  end
end
