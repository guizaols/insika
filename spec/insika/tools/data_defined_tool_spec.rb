# frozen_string_literal: true

require "spec_helper"
require "insika/tools/data_defined_tool" # the overlay loads it lazily; explicit in the test

RSpec.describe Insika::Tools::DataDefinedTool do
  # fake http: records the request, returns the configured result. Unique name to avoid
  # colliding with the ::FakeHttp from other specs (top-level constant via `class`).
  class FakeDataHttp
    attr_reader :last

    def initialize(result) = (@result = result)
    def request(**req) = (@last = req; @result)
  end

  # permissive egress (the real guard has its own spec; here we don't want DNS).
  PermissiveEgress = Class.new { def violation(*, **) = nil }.new

  let(:events) { [] }
  let(:event_stream) { Class.new { def initialize(s) = (@s = s); def emit(e) = @s << e }.new(events) }

  def tool(definition_attrs, result:, egress: PermissiveEgress, egress_options: {})
    d = Insika::ToolDefinition.build(**definition_attrs)
    described_class.new(definition: d, http: FakeDataHttp.new(result), egress: egress,
                        egress_options: egress_options, event_stream: event_stream)
  end

  let(:cep_def) do
    { name: "cep", description: "Consulta CEP",
      parameters: [{ name: "cep", type: "string", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" } }
  end

  it "name/description/parameters per instance; params_schema is derived" do
    t = tool(cep_def, result: { status: 200, body: "{}" })
    expect(t.name).to eq("cep")
    expect(t.description).to eq("Consulta CEP")
    expect(t.parameters.keys).to eq([:cep])
    expect(t.params_schema["properties"]).to have_key("cep")
    expect(t.params_schema["required"]).to include("cep")
  end

  # Phase 7, Stage A — PROOF: a NESTED parameter (search_products) is exposed to the
  # model via params_schema (what the providers serialize) AND interpolated into the body.
  describe "nested param (JSON Schema)" do
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

    it "exposes the nested schema to the model via params_schema" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      schema = t.params_schema
      items = schema.dig("properties", "query_filter_pairs", "items")
      expect(items["type"]).to eq("object")
      expect(items["properties"]).to have_key("query")
      expect(items.dig("properties", "filters", "type")).to eq("object")
    end

    it "interpolates the nested value (array of objects) into the body as JSON" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      pairs = [{ "query" => "arroz", "filters" => { "brand" => "tio" } }]
      t.execute(query_filter_pairs: pairs)
      body = t.instance_variable_get(:@http).last[:body]
      expect(JSON.parse(body)).to eq("pairs" => pairs)
    end

    # The production failure: the model sent a list of STRINGS for a list of objects.
    # It used to be interpolated as-is, the backend answered 200, and the wrong results
    # came back with no error anywhere. Now the call never leaves the process.
    it "a list of strings where the schema declares objects -> {error:}, no HTTP call" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      expect(t.execute(query_filter_pairs: ["trufa Acme"]))
        .to match(error: /query_filter_pairs\[0\]: expected an object/)
      expect(t.instance_variable_get(:@http).last).to be_nil
    end

    it "names the missing nested property so the model can retry correctly" do
      t = tool(search_def, result: { status: 200, body: "ok" })
      expect(t.execute(query_filter_pairs: [{ "filters" => {} }]))
        .to match(error: /query_filter_pairs\[0\]\.query: missing/)
    end
  end

  def last_url(t) = t.instance_variable_get(:@http).last[:url]

  it "GET + json_path: interpolates the URL, extracts the path" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"São Paulo"}' })
    expect(t.execute(cep: "01001000")).to eq("São Paulo")
    expect(last_url(t)).to eq("https://viacep.com.br/ws/01001000/json")
  end

  it "percent-encodes a value in the URL" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"x"}' })
    t.execute(cep: "a b/c")
    expect(last_url(t)).to eq("https://viacep.com.br/ws/a%20b%2Fc/json")
  end

  it "body_raw returns the raw body; HTTP>=400 becomes {error:}" do
    ok = tool(cep_def.merge(response: { extract: "body_raw" }), result: { status: 200, body: "PONG" })
    expect(ok.execute(cep: "1")).to eq("PONG")
    bad = tool(cep_def.merge(response: { extract: "body_raw" }), result: { status: 404, body: "nope" })
    expect(bad.execute(cep: "1")).to match(error: /HTTP 404/)
  end

  # A failure body is often the backend TALKING (status + instruction). Flattened into
  # a 200-char slice, the instruction was lost exactly when the model needed it.
  describe "a JSON body on a failure" do
    let(:def_raw) { cep_def.merge(response: { extract: "body_raw" }) }

    it "rides along parsed, under its own key" do
      envelope = '{"tool_result":{"status":"NOT_FOUND","llm_instruction":"peça para a pessoa recomeçar"}}'
      out = tool(def_raw, result: { status: 404, body: envelope }).execute(cep: "1")
      expect(out[:error]).to eq("HTTP 404")                                 # still an error
      expect(out[:body]["tool_result"]["status"]).to eq("NOT_FOUND")        # and still readable
      expect(out[:body]["tool_result"]["llm_instruction"]).to include("recomeçar")
    end

    it "a non-JSON body stays truncated — an HTML error page is noise, not a message" do
      out = tool(def_raw, result: { status: 500, body: "<html>#{'x' * 500}</html>" }).execute(cep: "1")
      expect(out[:error]).to start_with("HTTP 500: <html>")
      expect(out).not_to have_key(:body)
      expect(out[:error].bytesize).to be < 250
    end

    it "an oversized JSON body is not forwarded whole" do
      big = JSON.generate({ "items" => Array.new(400) { "padding-padding" } })
      out = tool(def_raw, result: { status: 502, body: big }).execute(cep: "1")
      expect(out).not_to have_key(:body)
      expect(out[:error]).to start_with("HTTP 502:")
    end
  end

  # A moved API is the way a data-tool rots: the HttpClient does not follow the
  # hop (the EgressGuard only cleared the authored URL), and a 3xx carries an
  # EMPTY body — counted as success, the model got "" and narrated an outage.
  describe "a redirect (the API moved)" do
    let(:moved) { { status: 301, body: "", location: "https://api.example.test/v2/latest" } }

    it "body_raw -> {error:} naming the new URL, never the empty body" do
      t = tool(cep_def.merge(response: { extract: "body_raw" }), result: moved)
      expect(t.execute(cep: "1")).to eq(error: "HTTP 301: moved to https://api.example.test/v2/latest")
    end

    it "json_path -> {error:}, not 'response is not JSON'" do
      t = tool(cep_def, result: moved)
      expect(t.execute(cep: "1")).to match(error: /moved to/)
    end

    it "a 3xx without a Location still reports the status" do
      t = tool(cep_def.merge(response: { extract: "body_raw" }), result: { status: 304, body: "" })
      expect(t.execute(cep: "1")).to eq(error: "HTTP 304: ")
    end
  end

  it "extract status returns the status regardless of error" do
    t = tool(cep_def.merge(response: { extract: "status" }), result: { status: 503, body: "" })
    expect(t.execute(cep: "1")).to eq(status: 503)
  end

  it "missing json_path / non-JSON response become {error:}" do
    miss = tool(cep_def, result: { status: 200, body: '{"outro":1}' })
    expect(miss.execute(cep: "1")).to match(error: /not found/)
    nojson = tool(cep_def, result: { status: 200, body: "<html>" })
    expect(nojson.execute(cep: "1")).to match(error: /not JSON/)
  end

  it "missing required param -> {error:} (does not call HTTP)" do
    t = tool(cep_def, result: { status: 200, body: "{}" })
    expect(t.execute).to match(error: /missing required/)
  end

  it "blocked egress -> {error:} (does not call HTTP)" do
    blocking = Class.new { def violation(*, **) = "private-network destination blocked" }.new
    t = tool(cep_def, result: { status: 200, body: "{}" }, egress: blocking)
    expect(t.execute(cep: "1")).to match(error: /destination blocked/)
  end

  it "POST: interpolates query, header and body with JSON escaping" do
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
    expect(req[:body]).to eq('{"q":"a\"b"}')            # quotes escaped for valid JSON
  end

  # Phase 6/D2/G3: the TURN ids (not the model's) become X-Chat-Id/X-Store-Id/
  # X-Agent-Id — the PROOF of Stage B (without them every /api/internal/* tool 403s).
  describe "turn context {{ctx.*}}" do
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

    it "emits X-Chat-Id/X-Store-Id/X-Agent-Id from the turn context" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { chat_id: "chat-42", store_id: "loja-7", agent_id: "bia", tenant: "chat-42" }
      t.execute(sku: "ABC")
      h = headers_of(t)
      expect(h["X-Chat-Id"]).to eq("chat-42")
      expect(h["X-Store-Id"]).to eq("loja-7")
      expect(h["X-Agent-Id"]).to eq("bia")
      expect(h["Authorization"]).to eq("Bearer S3CR3T") # static secret, not ctx
      body = t.instance_variable_get(:@http).last[:body]
      expect(body).to eq('{"sku":"ABC","tenant":"chat-42"}')
    end

    it "accepts string keys in the turn context (JSON round-trip)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { "chat_id" => "c1", "store_id" => "s1", "agent_id" => "a1", "tenant" => "c1" }
      t.execute(sku: "X")
      expect(headers_of(t)["X-Chat-Id"]).to eq("c1")
    end

    it "missing ctx -> empty header (does not inject a model arg with the same name)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      # without turn_context set (default {})
      t.execute(sku: "X")
      expect(headers_of(t)["X-Store-Id"]).to eq("")
    end

    it "the model does NOT control ctx: a model arg 'chat_id' is ignored in ctx.*" do
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
      expect(h["X-Chat-Id"]).to eq("real-chat") # from the turn
      expect(h["X-Model"]).to eq("spoofed")     # from the model, separate channel
    end

    it "CRLF in a ctx value is stripped from the header (anti-injection)" do
      t = tool(internal_def, result: { status: 200, body: "" })
      t.turn_context = { chat_id: "a\r\nX-Evil: 1", store_id: "", agent_id: "", tenant: "" }
      t.execute(sku: "X")
      expect(headers_of(t)["X-Chat-Id"]).to eq("aX-Evil: 1")
    end
  end

  # halt_when: the RESPONSE ends the turn. The case that motivated it: the backend
  # performs the side effect AND sends its own confirmation to the customer — with the
  # model free to comment, the person gets the message twice.
  describe "halt_when" do
    let(:subscribe_def) do
      { name: "subscribe", description: "Inscreve",
        parameters: [{ name: "id", type: "integer", required: true }],
        request: { method: "POST", url: "https://app.test/subscribe", body: '{"id":"{{id}}"}' },
        halt_when: { json_path: "tool_result.status", equals: ["SUBSCRIBED"] } }
    end

    it "returns Tool::Halt when the status matches (RubyLLM ends its loop)" do
      body = '{"tool_result":{"status":"SUBSCRIBED","llm_instruction":"nada a dizer"}}'
      result = tool(subscribe_def, result: { status: 200, body: body }).execute(id: 6)
      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).to eq(body) # the payload still reaches the transcript
    end

    it "does NOT halt on another status — the model has to explain the failure" do
      body = '{"tool_result":{"status":"SUBSCRIPTION_FAILED","llm_instruction":"já inscrito"}}'
      result = tool(subscribe_def, result: { status: 200, body: body }).execute(id: 6)
      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect(result).to eq(body)
    end

    it "does NOT halt on a non-2xx that happens to carry the value (failure reaches the model)" do
      body = '{"tool_result":{"status":"SUBSCRIBED"}}'
      result = tool(subscribe_def, result: { status: 500, body: body }).execute(id: 6)
      expect(result).not_to be_a(RubyLLM::Tool::Halt)
    end

    it "does NOT halt on a non-JSON body — never end a turn on a guess" do
      result = tool(subscribe_def, result: { status: 200, body: "SUBSCRIBED" }).execute(id: 6)
      expect(result).not_to be_a(RubyLLM::Tool::Halt)
    end

    it "without halt_when nothing changes (the default is the model speaking)" do
      plain = subscribe_def.reject { |k, _| k == :halt_when }
      body = '{"tool_result":{"status":"SUBSCRIBED"}}'
      expect(tool(plain, result: { status: 200, body: body }).execute(id: 6)).to eq(body)
    end

    # `say`: what the customer gets when the model called the tool without writing a
    # lead-in. Before this, that turn published NOTHING — measured on a real store,
    # two escalation turns in a row delivered silence.
    describe "say" do
      def halting(say)
        subscribe_def.merge(halt_when: { json_path: "tool_result.status", equals: ["SUBSCRIBED"], say: say })
      end

      let(:body) { '{"tool_result":{"status":"SUBSCRIBED","message":"Já te inscrevi, chega em instantes."}}' }

      it "carries a literal the CHANNEL resolves — the control token, without forcing the prompt" do
        result = tool(halting({ text: "CALL_SUPPORT" }), result: { status: 200, body: body }).execute(id: 6)
        expect(Insika::ToolDefinition.halt_say_of(result.content)).to eq("CALL_SUPPORT")
      end

      it "carries a field of the backend's own answer" do
        result = tool(halting({ json_path: "tool_result.message" }), result: { status: 200, body: body }).execute(id: 6)
        expect(Insika::ToolDefinition.halt_say_of(result.content)).to eq("Já te inscrevi, chega em instantes.")
      end

      it "keeps the payload reachable for the trace" do
        result = tool(halting({ text: "CALL_SUPPORT" }), result: { status: 200, body: body }).execute(id: 6)
        expect(result.content[Insika::ToolDefinition::PAYLOAD_KEY]).to eq(body)
      end

      # Publishing a hash (or a number) to a person as the answer is never what
      # someone meant, so an unpublishable path reads as "no say".
      it "ignores a path that does not resolve to a string" do
        result = tool(halting({ json_path: "tool_result" }), result: { status: 200, body: body }).execute(id: 6)
        expect(Insika::ToolDefinition.halt_say_of(result.content)).to be_nil
      end

      it "leaves a halt with no say exactly as it was" do
        result = tool(subscribe_def, result: { status: 200, body: body }).execute(id: 6)
        expect(result.content).to eq(body)
      end

      # Two answers to "what does the customer get" is a config nobody can read.
      it "refuses both forms at load" do
        expect { tool(halting({ text: "X", json_path: "tool_result.message" }), result: { status: 200, body: body }) }
          .to raise_error(Insika::ValidationError, /exactly one of/)
      end

      it "refuses an empty say" do
        expect { tool(halting({}), result: { status: 200, body: body }) }
          .to raise_error(Insika::ValidationError, /exactly one of/)
      end
    end
  end

  it "emits :data_tool_call with status, without leaking body/secret" do
    t = tool(cep_def, result: { status: 200, body: '{"localidade":"X"}' })
    t.execute(cep: "1")
    ev = events.last
    expect(ev.type).to eq(:data_tool_call)
    expect(ev.data).to eq(tool: "cep", status: 200)
  end
end
