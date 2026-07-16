# frozen_string_literal: true

require "spec_helper"

# Fase 5 Etapa A: definição de tool por dados (value object + validação).
RSpec.describe Harness::ToolDefinition do
  def valid_attrs(**over)
    {
      name: "cep",
      description: "Consulta um CEP",
      parameters: [{ name: "cep", type: "string", description: "o CEP", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" }
    }.merge(over)
  end

  it "build normaliza defaults (headers/query, response body_raw, side_effect por método)" do
    d = described_class.build(name: "x", description: "d", request: { url: "https://a.test" })
    expect(d.request[:method]).to eq("GET")
    expect(d.request[:headers]).to eq({})
    expect(d.request[:query]).to eq({})
    expect(d.response).to eq({ extract: "body_raw", path: nil })
    expect(d.side_effect).to be(false)          # GET é idempotente
    # parameters vazio -> JSON Schema objeto vazio (Fase 7/D1)
    expect(d.parameters).to eq({ "type" => "object", "properties" => {}, "required" => [] })
  end

  it "side_effect default = true p/ método não-idempotente; override respeitado" do
    expect(described_class.build(name: "x", description: "d",
                                 request: { method: "post", url: "https://a.test" }).side_effect).to be(true)
    expect(described_class.build(name: "x", description: "d", side_effect: false,
                                 request: { method: "POST", url: "https://a.test" }).side_effect).to be(false)
  end

  it "from_h faz round-trip com to_h (string keys do store)" do
    d = described_class.build(**valid_attrs)
    again = described_class.from_h(d.to_h)
    expect(again).to eq(d)
  end

  # Fase 7/D4/F5 (Etapa C): group/tags como DADO.
  describe "group/tags" do
    it "default: group nil, tags []" do
      d = described_class.build(**valid_attrs)
      expect(d.group).to be_nil
      expect(d.tags).to eq([])
    end

    it "normaliza group (trim; vazio -> nil) e tags (strings não-vazias, únicas)" do
      d = described_class.build(**valid_attrs(group: "  b2b ", tags: ["x", "x", " ", "y"]))
      expect(d.group).to eq("b2b")
      expect(d.tags).to eq(%w[x y])
      expect(described_class.build(**valid_attrs(group: "   ")).group).to be_nil
    end

    it "round-trip to_h/from_h preserva group/tags" do
      d = described_class.build(**valid_attrs(group: "b2b", tags: ["catalog"]))
      again = described_class.from_h(d.to_h)
      expect(again).to eq(d)
      expect(d.to_h["group"]).to eq("b2b")
      expect(d.to_h["tags"]).to eq(["catalog"])
    end
  end

  describe "validação" do
    it "rejeita name fora do formato" do
      expect { described_class.build(**valid_attrs(name: "Bad Name")) }
        .to raise_error(Harness::ValidationError, /name deve casar/)
    end

    it "rejeita description vazia" do
      expect { described_class.build(**valid_attrs(description: "")) }
        .to raise_error(Harness::ValidationError, /description/)
    end

    it "rejeita method e url inválidos" do
      expect { described_class.build(**valid_attrs(request: { method: "FOO", url: "https://a.test" })) }
        .to raise_error(Harness::ValidationError, /method/)
      expect { described_class.build(**valid_attrs(request: { method: "GET", url: "ftp://a.test" })) }
        .to raise_error(Harness::ValidationError, /http/)
      expect { described_class.build(**valid_attrs(request: { method: "GET", url: "" })) }
        .to raise_error(Harness::ValidationError, /url é obrigatória/)
    end

    it "rejeita param com type inválido e nomes duplicados" do
      expect { described_class.build(**valid_attrs(parameters: [{ name: "a", type: "date" }])) }
        .to raise_error(Harness::ValidationError, /type inválido/)
      dup = [{ name: "a" }, { name: "a" }]
      expect { described_class.build(**valid_attrs(parameters: dup, request: { url: "https://a.test" })) }
        .to raise_error(Harness::ValidationError, /duplicado/)
    end

    it "rejeita json_path sem path" do
      expect { described_class.build(**valid_attrs(response: { extract: "json_path" })) }
        .to raise_error(Harness::ValidationError, /exige path/)
    end

    it "rejeita placeholder que não referencia parâmetro declarado" do
      attrs = valid_attrs(
        parameters: [{ name: "cep" }],
        request: { method: "POST", url: "https://a.test/{{cep}}", body: '{"x":"{{missing}}"}' }
      )
      expect { described_class.build(**attrs) }
        .to raise_error(Harness::ValidationError, /placeholder.*missing/)
    end

    it "aceita placeholder em url/query/headers/body quando declarado" do
      attrs = valid_attrs(
        parameters: [{ name: "q" }, { name: "tok" }],
        request: { method: "POST", url: "https://a.test/{{q}}",
                   query: { "term" => "{{q}}" }, headers: { "Authorization" => "Bearer {{tok}}" },
                   body: '{"q":"{{q}}"}' },
        response: { extract: "body_raw" }
      )
      expect { described_class.build(**attrs) }.not_to raise_error
    end

    # Fase 6/D2: namespace {{ctx.*}} = contexto de TURNO (não é param do modelo).
    describe "contexto de turno {{ctx.*}}" do
      it "aceita ctx.chat_id/store_id/agent_id/tenant sem declará-los como param" do
        attrs = valid_attrs(
          parameters: [{ name: "cep" }],
          request: { method: "POST", url: "https://a.test/{{cep}}",
                     headers: { "X-Chat-Id" => "{{ctx.chat_id}}", "X-Store-Id" => "{{ctx.store_id}}",
                                "X-Agent-Id" => "{{ ctx.agent_id }}" },
                     body: '{"t":"{{ctx.tenant}}"}' },
          response: { extract: "body_raw" }
        )
        expect { described_class.build(**attrs) }.not_to raise_error
      end

      it "rejeita campo de contexto desconhecido" do
        attrs = valid_attrs(
          parameters: [{ name: "cep" }],
          request: { method: "GET", url: "https://a.test/{{cep}}", headers: { "X" => "{{ctx.senha}}" } }
        )
        expect { described_class.build(**attrs) }
          .to raise_error(Harness::ValidationError, /contexto de turno desconhecido: ctx\.senha/)
      end

      it "não confunde ctx.* com parâmetro faltante" do
        attrs = valid_attrs(
          parameters: [], # nenhum param declarado
          request: { method: "GET", url: "https://a.test", headers: { "X-Chat-Id" => "{{ctx.chat_id}}" } }
        )
        expect { described_class.build(**attrs) }.not_to raise_error
      end
    end
  end

  it "required_params lista só os obrigatórios" do
    d = described_class.build(**valid_attrs(parameters: [
                                              { name: "a", required: true },
                                              { name: "b", required: false }
                                            ], request: { url: "https://a.test/{{a}}/{{b}}" }))
    expect(d.required_params).to eq(["a"])
  end

  # Fase 7/D1: parâmetros são JSON Schema; o array plano é açúcar que "sobe".
  describe "JSON Schema (Fase 7)" do
    it "sobe o array plano legado para JSON Schema (lift), sem regressão" do
      d = described_class.build(**valid_attrs)
      expect(d.parameters).to eq(
        "type" => "object",
        "properties" => { "cep" => { "type" => "string", "description" => "o CEP" } },
        "required" => ["cep"]
      )
    end

    it "array plano type=array ganha items string (paridade com o RubyLLM)" do
      d = described_class.build(**valid_attrs(parameters: [{ name: "tags", type: "array" }],
                                              request: { url: "https://a.test/{{tags}}" }))
      expect(d.parameters.dig("properties", "tags")).to eq("type" => "array", "items" => { "type" => "string" })
    end

    it "aceita JSON Schema aninhado (object/array) e o preserva string-keyed" do
      schema = {
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
      }
      d = described_class.build(name: "search_products", description: "busca",
                                parameters: schema,
                                request: { method: "POST", url: "https://a.test",
                                           body: '{"pairs":"{{query_filter_pairs}}"}' })
      expect(d.parameters).to eq(schema)
      expect(d.required_params).to eq(["query_filter_pairs"])
      expect(d.top_level_params).to eq([{ name: "query_filter_pairs", type: "array",
                                          description: "", required: true }])
    end

    it "aceita JSON Schema com symbol keys e normaliza p/ string" do
      d = described_class.build(name: "x", description: "d",
                                parameters: { type: "object", properties: { n: { type: "number" } }, required: [:n] },
                                request: { url: "https://a.test/{{n}}" })
      expect(d.parameters).to eq("type" => "object", "properties" => { "n" => { "type" => "number" } },
                                 "required" => ["n"])
    end

    it "round-trip from_h/to_h preserva o schema aninhado" do
      d = described_class.build(name: "search_products", description: "busca",
                                parameters: { "type" => "object",
                                              "properties" => { "q" => { "type" => "string" } },
                                              "required" => ["q"] },
                                request: { method: "POST", url: "https://a.test", body: '{"q":"{{q}}"}' })
      expect(described_class.from_h(d.to_h)).to eq(d)
    end

    describe "subset seguro (R1)" do
      def with_schema(schema)
        { name: "x", description: "d", parameters: schema, request: { url: "https://a.test" } }
      end

      it "rejeita composição (oneOf/anyOf/allOf/$ref)" do
        %w[oneOf anyOf allOf $ref].each do |kw|
          schema = { "type" => "object", "properties" => { "p" => { "type" => "string", kw => [] } } }
          expect { described_class.build(**with_schema(schema)) }
            .to raise_error(Harness::ValidationError, /não suportada/), "esperava rejeitar #{kw}"
        end
      end

      it "rejeita type fora do subset seguro" do
        schema = { "type" => "object", "properties" => { "p" => { "type" => "null" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Harness::ValidationError, /type inválido/)
      end

      it "rejeita array sem items" do
        schema = { "type" => "object", "properties" => { "p" => { "type" => "array" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Harness::ValidationError, /array exige 'items'/)
      end

      it "rejeita required citando propriedade inexistente" do
        schema = { "type" => "object", "properties" => { "a" => { "type" => "string" } }, "required" => ["b"] }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Harness::ValidationError, /propriedade inexistente: b/)
      end

      it "rejeita topo que não é object" do
        expect { described_class.build(**with_schema({ "type" => "array", "items" => { "type" => "string" } })) }
          .to raise_error(Harness::ValidationError, /topo.*deve ser type object/)
      end

      it "rejeita nome de propriedade de topo fora do NAME_RE" do
        schema = { "type" => "object", "properties" => { "Bad Name" => { "type" => "string" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Harness::ValidationError, /param de topo.*deve casar/)
      end

      it "aceita enum e min/max (subset seguro)" do
        schema = {
          "type" => "object",
          "properties" => {
            "size" => { "type" => "string", "enum" => %w[s m l] },
            "qty" => { "type" => "integer", "minimum" => 1, "maximum" => 10 }
          },
          "required" => ["size"]
        }
        expect { described_class.build(**with_schema(schema)) }.not_to raise_error
      end
    end
  end
end
