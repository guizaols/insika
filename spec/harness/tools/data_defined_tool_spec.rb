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

  it "emite :data_tool_call com status, sem vazar corpo/segredo" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"X"}' })
    t.execute(cep: "1")
    ev = events.last
    expect(ev.type).to eq(:data_tool_call)
    expect(ev.data).to eq(tool: "cep", status: 200)
  end
end
