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

  describe "#resolve(profile) — atalho DEPRECATED (paridade Fase 0)" do
    before do
      registry.register("a", tool_class(:a))                 # required
      registry.register("b", tool_class(:b), optional: true) # optional
    end

    def resolve_markers(prof)
      silence_deprecation { registry.resolve(prof) }.map { |t| t.new.marker }
    end

    it "required entra; optional sem opt-in fica de fora" do
      expect(resolve_markers(profile(tools_allow: nil))).to eq([:a])
    end

    it "optional com opt-in entra" do
      expect(resolve_markers(profile(tools_allow: %w[a b]))).to contain_exactly(:a, :b)
    end

    it "deny sempre vence" do
      expect(resolve_markers(profile(tools_allow: %w[a], tools_deny: %w[a]))).to eq([])
    end

    it "allow [] -> nenhuma (D6, divergência intencional da Fase 0)" do
      expect(resolve_markers(profile(tools_allow: []))).to eq([])
    end

    it "emite deprecation warning" do
      expect { registry.resolve(profile(tools_allow: nil)) }
        .to output(/DEPRECATION.*ToolRegistry#resolve/).to_stderr
    end
  end

  def silence_deprecation
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
