# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TextToolCall do
  let(:known) { %w[search_faq search_products] }

  # Verbatim from the Loja Exemplo session, 23/10/2026.
  let(:leaked) do
    "<tool_call>\nsearch_faq\n<parameter name=\"query\">quem é a loja Exemplo, " \
      "e o que ela vende</parameter>\n</tool_call>"
  end

  it "reads the name-then-parameter spelling deepseek-v4-flash leaked" do
    expect(described_class.parse(leaked, known)).to eq(
      calls: [{ name: "search_faq",
                arguments: { "query" => "quem é a loja Exemplo, e o que ela vende" } }],
      text: ""
    )
  end

  it "reads the JSON spelling, with arguments as an object or as a JSON string" do
    object = '<tool_call>{"name": "search_products", "arguments": {"query": "terço"}}</tool_call>'
    string = '<tool_call>{"name": "search_products", "arguments": "{\"query\": \"terço\"}"}</tool_call>'

    aggregate_failures do
      [object, string].each do |content|
        expect(described_class.parse(content, known)[:calls])
          .to eq([{ name: "search_products", arguments: { "query" => "terço" } }])
      end
    end
  end

  it "keeps the text around the blocks and reads every block" do
    content = "Vou conferir.\n#{leaked}\n<tool_call>search_products\n" \
              "<parameter name=\"query\">terço</parameter></tool_call>"
    parsed = described_class.parse(content, known)

    aggregate_failures do
      expect(parsed[:text]).to eq("Vou conferir.")
      expect(parsed[:calls].map { |call| call[:name] }).to eq(%w[search_faq search_products])
    end
  end

  it "recovers nothing it cannot name: unknown tool, unreadable block or plain prose" do
    aggregate_failures do
      expect(described_class.parse(leaked, %w[search_products])).to be_nil
      expect(described_class.parse("<tool_call>{not json</tool_call>", known)).to be_nil
      expect(described_class.parse("Somos sim, de tradição varejista.", known)).to be_nil
    end
  end

  context "with DeepSeek DSML markup" do
    let(:known) { %w[call_support search_products] }

    # Verbatim from niini, session ae38c6fe, 09/11/2026: the tool name as the tag,
    # a DSML closing tag, and no closing for the call itself.
    let(:niini) { "<call_support>\n<parameter name=\"reason\">pedido_atendimento_humano</｜｜DSML｜｜ parameter>\n" }

    it "reads the tool-name-as-tag spelling, even cut before its closing tag" do
      expect(described_class.parse(niini, known)).to eq(
        calls: [{ name: "call_support", arguments: { "reason" => "pedido_atendimento_humano" } }],
        text: ""
      )
    end

    it "reads the native invoke spelling" do
      content = "<｜｜DSML｜｜function_calls>\n<｜｜DSML｜｜invoke name=\"search_products\">\n" \
                "<｜｜DSML｜｜parameter name=\"query\" string=\"true\">blazer</｜｜DSML｜｜parameter>\n" \
                "</｜｜DSML｜｜invoke>\n</｜｜DSML｜｜function_calls>"
      expect(described_class.parse(content, known)[:calls])
        .to eq([{ name: "search_products", arguments: { "query" => "blazer" } }])
    end

    it "recovers nothing when the name is gone (natura, 08/11/2026)" do
      content = "<parameter name=\"description\">desodorante roll-on</｜｜DSML｜｜ parameter>\n" \
                "</｜｜DSML｜｜ invoke>\n</｜｜DSML｜｜ calls>"
      expect(described_class.parse(content, known)).to be_nil
    end
  end

  describe ".strip_markup" do
    it "keeps the prose before the markup and drops the rest" do
      aggregate_failures do
        expect(described_class.strip_markup("Vou ver.\n<parameter name=\"q\">x</｜｜DSML｜｜ parameter>")).to eq("Vou ver.")
        expect(described_class.strip_markup("<call_support>\n<parameter name=\"r\">x")).to eq("")
        expect(described_class.strip_markup("Oi, tudo bem?")).to eq("Oi, tudo bem?")
      end
    end
  end
end
