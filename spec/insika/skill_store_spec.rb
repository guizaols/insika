# frozen_string_literal: true

require "spec_helper"

# Phase 4 Step C: shared authored skills (SKILL.md in the durable Store).
RSpec.describe Insika::SkillStore do
  subject(:store) { described_class.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new)) }

  def skill_md(name, body = "body") = "---\nname: #{name}\ndescription: d\n---\n#{body}\n"

  it "write/get round-trip; names/all list the authored ones" do
    store.write("pedido", skill_md("pedido"))
    store.write("cardapio", skill_md("cardapio"))

    expect(store.get("pedido")).to eq(skill_md("pedido"))
    expect(store.names).to eq(%w[cardapio pedido])           # lexicographic
    expect(store.all.keys).to contain_exactly("pedido", "cardapio")
  end

  it "overwriting versions; create_only refuses" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    expect(store.versions("pedido").map { |h| h["content"] }).to eq([skill_md("pedido", "v1")])
    expect { store.write("pedido", skill_md("pedido"), create_only: true) }
      .to raise_error(Insika::ValidationError, /already exists/)
  end

  it "delete -> bool; restore reverts to an old version" do
    store.write("pedido", skill_md("pedido", "v1"))
    store.write("pedido", skill_md("pedido", "v2"))
    store.restore("pedido", 0)
    expect(store.get("pedido")).to eq(skill_md("pedido", "v1"))
    expect(store.delete("pedido")).to be(true)
    expect(store.delete("pedido")).to be(false)
  end
end
