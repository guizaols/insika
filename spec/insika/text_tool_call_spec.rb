# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::TextToolCall do
  let(:known) { %w[search_faq search_products] }

  # Verbatim from the Loja Mensageiros session, 23/10/2026.
  let(:leaked) do
    "<tool_call>\nsearch_faq\n<parameter name=\"query\">quem é a loja Mensageiros, " \
      "ligação com a ordem carmelita</parameter>\n</tool_call>"
  end

  it "reads the name-then-parameter spelling deepseek-v4-flash leaked" do
    expect(described_class.parse(leaked, known)).to eq(
      calls: [{ name: "search_faq",
                arguments: { "query" => "quem é a loja Mensageiros, ligação com a ordem carmelita" } }],
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
      expect(described_class.parse("Somos sim, de tradição carmelita.", known)).to be_nil
    end
  end
end
