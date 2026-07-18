# frozen_string_literal: true

require "spec_helper"

# Tolerant frontmatter parser: YAML when possible, otherwise line-based. The
# motivating case (real packs): prose with `: ` in the description, which strict
# YAML rejects.
RSpec.describe Harness::Frontmatter do
  it "parses simple YAML (name/description)" do
    meta = described_class.parse("name: cardapio\ndescription: mostra o cardápio")
    expect(meta).to eq("name" => "cardapio", "description" => "mostra o cardápio")
  end

  it "tolerates `: ` in the description prose (strict YAML would break)" do
    fm = "name: gift-consultant-heuristics\n" \
         "description: Discovery heuristics. Acme sells chocolate/gift: there is NO size gate. Enable it in discovery."
    meta = described_class.parse(fm)
    expect(meta["name"]).to eq("gift-consultant-heuristics")
    expect(meta["description"]).to include("gift: there is NO size gate") # inner `: ` preserved
  end

  it "respects quoted YAML (quoted keeps working)" do
    meta = described_class.parse(%(name: x\ndescription: "a: b, c"))
    expect(meta["description"]).to eq("a: b, c")
  end

  it "ignores lines without `:` in the fallback and does not raise" do
    meta = described_class.parse("name: só-nome: com dois pontos\nlinha solta sem separador")
    expect(meta["name"]).to eq("só-nome: com dois pontos") # split on the FIRST `:`
  end

  it "empty frontmatter -> {}" do
    expect(described_class.parse("")).to eq({})
  end
end
