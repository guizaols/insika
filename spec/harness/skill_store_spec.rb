# frozen_string_literal: true

require "spec_helper"

# Fase 4 Etapa C: skills compartilhadas autoradas (SKILL.md no Store durável).
RSpec.describe Harness::SkillStore do
  subject(:store) { described_class.new(config_store: Harness::ConfigStore.new(store: Harness::Stores::Memory.new)) }

  def skill_md(name, body = "corpo") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  it "write/get round-trip; names/all listam as autoradas" do
    store.write("pedido", skill_md("pedido"))
    store.write("cardapio", skill_md("cardapio"))

    expect(store.get("pedido")).to eq(skill_md("pedido"))
    expect(store.names).to eq(%w[cardapio pedido])           # lexicográfico
    expect(store.all.keys).to contain_exactly("pedido", "cardapio")
  end

  it "sobrescrever versiona; create_only recusa" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    expect(store.versions("pedido").map { |h| h["content"] }).to eq([skill_md("pedido", "v1")])
    expect { store.write("pedido", skill_md("pedido"), create_only: true) }
      .to raise_error(Harness::ValidationError, /já existe/)
  end

  it "delete -> bool; restore volta uma versão antiga" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    store.restore("pedido", 0)
    expect(store.get("pedido")).to eq(skill_md("pedido", "v1"))
    expect(store.delete("pedido")).to be(true)
    expect(store.delete("pedido")).to be(false)
  end
end
