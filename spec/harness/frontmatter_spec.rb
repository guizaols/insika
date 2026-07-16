# frozen_string_literal: true

require "spec_helper"

# Parser tolerante de frontmatter: YAML quando dá, senão line-based. O caso que
# motivou (packs reais): prosa com `: ` no description, que o YAML estrito rejeita.
RSpec.describe Harness::Frontmatter do
  it "parseia YAML simples (name/description)" do
    meta = described_class.parse("name: cardapio\ndescription: mostra o cardápio")
    expect(meta).to eq("name" => "cardapio", "description" => "mostra o cardápio")
  end

  it "tolera `: ` na prosa do description (YAML estrito quebraria)" do
    fm = "name: gift-consultant-heuristics\n" \
         "description: Heurísticas de discovery. Acme vende chocolate/presente: NÃO há size gate. Ative no discovery."
    meta = described_class.parse(fm)
    expect(meta["name"]).to eq("gift-consultant-heuristics")
    expect(meta["description"]).to include("presente: NÃO há size gate") # `: ` interno preservado
  end

  it "respeita YAML com aspas (quoted continua funcionando)" do
    meta = described_class.parse(%(name: x\ndescription: "a: b, c"))
    expect(meta["description"]).to eq("a: b, c")
  end

  it "ignora linhas sem `:` no fallback e não levanta" do
    meta = described_class.parse("name: só-nome: com dois pontos\nlinha solta sem separador")
    expect(meta["name"]).to eq("só-nome: com dois pontos") # split no PRIMEIRO `:`
  end

  it "frontmatter vazio -> {}" do
    expect(described_class.parse("")).to eq({})
  end
end
