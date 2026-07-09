# frozen_string_literal: true

require "spec_helper"
require "harness/tools/load_skill" # carregado lazy em produção; explícito no teste

RSpec.describe Harness::Tools::LoadSkill do
  # Catálogo duplo com a superfície usada (find -> Skill|nil).
  Skill = Struct.new(:name, :body)

  let(:catalog) do
    instance_double("Harness::SkillCatalog").tap do |c|
      allow(c).to receive(:find) { |name| name == "cardapio" ? Skill.new("cardapio", "CORPO") : nil }
    end
  end

  it "retorna o corpo da skill quando permitida e presente" do
    tool = described_class.new(catalog, ["cardapio"])

    expect(tool.execute(name: "cardapio")).to eq("CORPO")
  end

  it "recusa skill fora da allowlist (sem levantar)" do
    tool = described_class.new(catalog, ["pedido"])

    expect(tool.execute(name: "cardapio")).to eq({ error: "skill 'cardapio' não disponível para este agente" })
  end

  it "reporta skill permitida mas inexistente no catálogo" do
    tool = described_class.new(catalog, ["fantasma"])

    expect(tool.execute(name: "fantasma")).to eq({ error: "skill 'fantasma' não encontrada" })
  end
end
