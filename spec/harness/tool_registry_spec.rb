# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::ToolRegistry do
  subject(:registry) { described_class.new }

  def tool_class(marker)
    Class.new { define_method(:marker) { marker } }
  end

  def profile(**over)
    Harness::AgentProfile.build(**{ id: "a", model: "m" }.merge(over))
  end

  describe "metadata (doc 06 §2)" do
    it "defaults optional/side_effect false" do
      registry.register("t", tool_class(:t))
      expect(registry.entries.first.metadata).to eq({ optional: false, side_effect: false })
    end

    it "side_effect: true explícito" do
      registry.register("t", tool_class(:t), side_effect: true)
      expect(registry.entries.first.metadata[:side_effect]).to be(true)
      expect(registry.side_effect?("t")).to be(true)
    end

    it "compat Fase 0: optional/plugin preservados" do
      registry.register("t", tool_class(:t), optional: true, plugin: "p")
      entry = registry.entries.first
      expect(entry.metadata[:optional]).to be(true)
      expect(entry.plugin).to eq("p")
    end

    it "side_effect? de tool desconhecida -> false" do
      expect(registry.side_effect?("nope")).to be(false)
    end
  end

  describe "#resolve(name) — contrato do genérico" do
    it "devolve instância via factory" do
      klass = tool_class(:a)
      registry.register("a", klass)
      expect(registry.resolve("a")).to eq(klass)
    end

    it "nome inexistente -> NotFoundError" do
      expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
    end
  end

end
