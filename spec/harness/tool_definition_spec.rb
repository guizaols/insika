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
    expect(d.parameters).to eq([])
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
end
