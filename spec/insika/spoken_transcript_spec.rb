# frozen_string_literal: true

require "spec_helper"

# What an extractor reads: user/assistant prose only, original indices kept.
RSpec.describe Insika::SpokenTranscript do
  it "drops role: tool messages and blank assistant tool-call shells; keeps the original indices" do
    messages = [
      { "role" => "user", "content" => "quero um tênis" },
      { "role" => "assistant", "content" => nil, "tool_calls" => [{ "id" => "c1", "name" => "search_products" }] },
      { "role" => "tool", "tool_call_id" => "c1", "content" => "Tênis Runner — o cliente sempre compra tamanho 44" },
      { role: :assistant, content: "Achei o Runner. Qual seu tamanho?" }
    ]
    expect(described_class.render(messages)).to eq(
      "[0] user: quero um tênis\n[3] assistant: Achei o Runner. Qual seu tamanho?"
    )
  end

  it "redacts PII like the persisted transcript does" do
    out = described_class.render([{ "role" => "user", "content" => "meu cpf é 111.222.333-44" }])
    expect(out).to eq("[0] user: meu cpf é [REDACTED:cpf]")
  end

  it "nil/empty -> empty string" do
    expect(described_class.render(nil)).to eq("")
    expect(described_class.render([])).to eq("")
  end
end
