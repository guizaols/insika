# frozen_string_literal: true

require "spec_helper"

# data-driven tool definition (value object + validation).
RSpec.describe Insika::ToolDefinition do
  def valid_attrs(**over)
    {
      name: "cep",
      description: "Consulta um CEP",
      parameters: [{ name: "cep", type: "string", description: "o CEP", required: true }],
      request: { method: "GET", url: "https://viacep.com.br/ws/{{cep}}/json" },
      response: { extract: "json_path", path: "localidade" }
    }.merge(over)
  end

  it "build normalizes defaults (headers/query, response body_raw, side_effect by method)" do
    d = described_class.build(name: "x", description: "d", request: { url: "https://a.test" })
    expect(d.request[:method]).to eq("GET")
    expect(d.request[:headers]).to eq({})
    expect(d.request[:query]).to eq({})
    expect(d.response).to eq({ extract: "body_raw", path: nil })
    expect(d.side_effect).to be(false)          # GET is idempotent
    # empty parameters -> empty JSON Schema object
    expect(d.parameters).to eq({ "type" => "object", "properties" => {}, "required" => [] })
  end

  it "side_effect default = true for a non-idempotent method; override respected" do
    expect(described_class.build(name: "x", description: "d",
                                 request: { method: "post", url: "https://a.test" }).side_effect).to be(true)
    expect(described_class.build(name: "x", description: "d", side_effect: false,
                                 request: { method: "POST", url: "https://a.test" }).side_effect).to be(false)
  end

  it "from_h round-trips with to_h (string keys from the store)" do
    d = described_class.build(**valid_attrs)
    again = described_class.from_h(d.to_h)
    expect(again).to eq(d)
  end

  # group/tags as DATA.
  describe "group/tags" do
    it "default: group nil, tags []" do
      d = described_class.build(**valid_attrs)
      expect(d.group).to be_nil
      expect(d.tags).to eq([])
    end

    it "normalizes group (trim; empty -> nil) and tags (non-empty, unique strings)" do
      d = described_class.build(**valid_attrs(group: "  b2b ", tags: ["x", "x", " ", "y"]))
      expect(d.group).to eq("b2b")
      expect(d.tags).to eq(%w[x y])
      expect(described_class.build(**valid_attrs(group: "   ")).group).to be_nil
    end

    it "round-trip to_h/from_h preserves group/tags" do
      d = described_class.build(**valid_attrs(group: "b2b", tags: ["catalog"]))
      again = described_class.from_h(d.to_h)
      expect(again).to eq(d)
      expect(d.to_h["group"]).to eq("b2b")
      expect(d.to_h["tags"]).to eq(["catalog"])
    end
  end

  describe "validation" do
    it "rejects a name outside the format" do
      expect { described_class.build(**valid_attrs(name: "Bad Name")) }
        .to raise_error(Insika::ValidationError, /name must match/)
    end

    it "rejects an empty description" do
      expect { described_class.build(**valid_attrs(description: "")) }
        .to raise_error(Insika::ValidationError, /description/)
    end

    it "rejects invalid method and url" do
      expect { described_class.build(**valid_attrs(request: { method: "FOO", url: "https://a.test" })) }
        .to raise_error(Insika::ValidationError, /method/)
      expect { described_class.build(**valid_attrs(request: { method: "GET", url: "ftp://a.test" })) }
        .to raise_error(Insika::ValidationError, /http/)
      expect { described_class.build(**valid_attrs(request: { method: "GET", url: "" })) }
        .to raise_error(Insika::ValidationError, /url is required/)
    end

    it "rejects a param with invalid type and duplicated names" do
      expect { described_class.build(**valid_attrs(parameters: [{ name: "a", type: "date" }])) }
        .to raise_error(Insika::ValidationError, /invalid type/)
      dup = [{ name: "a" }, { name: "a" }]
      expect { described_class.build(**valid_attrs(parameters: dup, request: { url: "https://a.test" })) }
        .to raise_error(Insika::ValidationError, /duplicated/)
    end

    it "rejects json_path without path" do
      expect { described_class.build(**valid_attrs(response: { extract: "json_path" })) }
        .to raise_error(Insika::ValidationError, /requires path/)
    end

    it "rejects a placeholder that does not reference a declared parameter" do
      attrs = valid_attrs(
        parameters: [{ name: "cep" }],
        request: { method: "POST", url: "https://a.test/{{cep}}", body: '{"x":"{{missing}}"}' }
      )
      expect { described_class.build(**attrs) }
        .to raise_error(Insika::ValidationError, /placeholder.*missing/)
    end

    it "accepts a placeholder in url/query/headers/body when declared" do
      attrs = valid_attrs(
        parameters: [{ name: "q" }, { name: "tok" }],
        request: { method: "POST", url: "https://a.test/{{q}}",
                   query: { "term" => "{{q}}" }, headers: { "Authorization" => "Bearer {{tok}}" },
                   body: '{"q":"{{q}}"}' },
        response: { extract: "body_raw" }
      )
      expect { described_class.build(**attrs) }.not_to raise_error
    end

    # namespace {{ctx.*}} = TURN context (not a model param).
    describe "turn context {{ctx.*}}" do
      it "accepts ctx.chat_id/store_id/agent_id/tenant/image_url without declaring them as params" do
        attrs = valid_attrs(
          parameters: [{ name: "cep" }],
          request: { method: "POST", url: "https://a.test/{{cep}}",
                     headers: { "X-Chat-Id" => "{{ctx.chat_id}}", "X-Store-Id" => "{{ctx.store_id}}",
                                "X-Agent-Id" => "{{ ctx.agent_id }}" },
                     body: '{"t":"{{ctx.tenant}}","photo":"{{ctx.image_url}}"}' },
          response: { extract: "body_raw" }
        )
        expect { described_class.build(**attrs) }.not_to raise_error
      end

      it "rejects an unknown context field" do
        attrs = valid_attrs(
          parameters: [{ name: "cep" }],
          request: { method: "GET", url: "https://a.test/{{cep}}", headers: { "X" => "{{ctx.senha}}" } }
        )
        expect { described_class.build(**attrs) }
          .to raise_error(Insika::ValidationError, /unknown turn context: ctx\.senha/)
      end

      it "does not confuse ctx.* with a missing parameter" do
        attrs = valid_attrs(
          parameters: [], # no param declared
          request: { method: "GET", url: "https://a.test", headers: { "X-Chat-Id" => "{{ctx.chat_id}}" } }
        )
        expect { described_class.build(**attrs) }.not_to raise_error
      end
    end
  end

  it "required_params lists only the required ones" do
    d = described_class.build(**valid_attrs(parameters: [
                                              { name: "a", required: true },
                                              { name: "b", required: false }
                                            ], request: { url: "https://a.test/{{a}}/{{b}}" }))
    expect(d.required_params).to eq(["a"])
  end

  # parameters are JSON Schema; the flat array is sugar that "lifts".
  describe "JSON Schema" do
    it "lifts the legacy flat array to JSON Schema (lift), without regression" do
      d = described_class.build(**valid_attrs)
      expect(d.parameters).to eq(
        "type" => "object",
        "properties" => { "cep" => { "type" => "string", "description" => "o CEP" } },
        "required" => ["cep"]
      )
    end

    # The engine does NOT invent an item type. A bare `array` used to lift to
    # `items: {type:"string"}`, which is how an array-of-objects param reached a
    # provider declared as an array of strings — the model obeyed, the backend
    # answered 200, and nothing anywhere reported an error.
    it "refuses a flat param typed bare 'array', naming the spelling that fixes it" do
      expect { described_class.build(**valid_attrs(parameters: [{ name: "tags", type: "array" }],
                                                   request: { url: "https://a.test/{{tags}}" })) }
        .to raise_error(Insika::ValidationError, /'tags'.*needs an item type.*array:string/)
    end

    it "lifts array:<scalar> into items" do
      %w[string number integer boolean].each do |item|
        d = described_class.build(**valid_attrs(parameters: [{ name: "tags", type: "array:#{item}" }],
                                                request: { url: "https://a.test/{{tags}}" }))
        expect(d.parameters.dig("properties", "tags")).to eq("type" => "array", "items" => { "type" => item })
      end
    end

    it "lifts a flat integer param" do
      d = described_class.build(**valid_attrs(parameters: [{ name: "qty", type: "integer" }],
                                              request: { url: "https://a.test/{{qty}}" }))
      expect(d.parameters.dig("properties", "qty")).to eq("type" => "integer")
    end

    it "rejects an unknown flat type, listing the accepted ones" do
      expect { described_class.build(**valid_attrs(parameters: [{ name: "x", type: "object" }],
                                                   request: { url: "https://a.test/{{x}}" })) }
        .to raise_error(Insika::ValidationError, %r{invalid type "object".*array:string}m)
    end

    it "accepts nested JSON Schema (object/array) and preserves it string-keyed" do
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

    it "accepts JSON Schema with symbol keys and normalizes to string" do
      d = described_class.build(name: "x", description: "d",
                                parameters: { type: "object", properties: { n: { type: "number" } }, required: [:n] },
                                request: { url: "https://a.test/{{n}}" })
      expect(d.parameters).to eq("type" => "object", "properties" => { "n" => { "type" => "number" } },
                                 "required" => ["n"])
    end

    it "round-trip from_h/to_h preserves the nested schema" do
      d = described_class.build(name: "search_products", description: "busca",
                                parameters: { "type" => "object",
                                              "properties" => { "q" => { "type" => "string" } },
                                              "required" => ["q"] },
                                request: { method: "POST", url: "https://a.test", body: '{"q":"{{q}}"}' })
      expect(described_class.from_h(d.to_h)).to eq(d)
    end

    describe "safe subset (R1)" do
      def with_schema(schema)
        { name: "x", description: "d", parameters: schema, request: { url: "https://a.test" } }
      end

      it "rejects composition (oneOf/anyOf/allOf/$ref)" do
        %w[oneOf anyOf allOf $ref].each do |kw|
          schema = { "type" => "object", "properties" => { "p" => { "type" => "string", kw => [] } } }
          expect { described_class.build(**with_schema(schema)) }
            .to raise_error(Insika::ValidationError, /unsupported/), "expected to reject #{kw}"
        end
      end

      it "rejects a type outside the safe subset" do
        schema = { "type" => "object", "properties" => { "p" => { "type" => "null" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Insika::ValidationError, /invalid type/)
      end

      it "rejects an array without items" do
        schema = { "type" => "object", "properties" => { "p" => { "type" => "array" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Insika::ValidationError, /array requires 'items'/)
      end

      it "rejects required citing a nonexistent property" do
        schema = { "type" => "object", "properties" => { "a" => { "type" => "string" } }, "required" => ["b"] }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Insika::ValidationError, /nonexistent property: b/)
      end

      it "rejects a top level that is not an object" do
        expect { described_class.build(**with_schema({ "type" => "array", "items" => { "type" => "string" } })) }
          .to raise_error(Insika::ValidationError, /top.*must be type object/)
      end

      it "rejects a top-level property name outside NAME_RE" do
        schema = { "type" => "object", "properties" => { "Bad Name" => { "type" => "string" } } }
        expect { described_class.build(**with_schema(schema)) }
          .to raise_error(Insika::ValidationError, /top-level param.*must match/)
      end

      it "accepts enum and min/max (safe subset)" do
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
