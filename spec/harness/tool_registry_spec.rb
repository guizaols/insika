# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::ToolRegistry do
  subject(:registry) { described_class.new }

  # tool dummy só com um nome reconhecível.
  def tool_class(marker)
    Class.new { define_method(:marker) { marker } }
  end

  def profile(**over)
    Harness::AgentProfile.build(**{ id: "a", model: "m" }.merge(over))
  end

  describe "register/names/entries" do
    it "registra por classe e por bloco; entries devolve Entry; factory devolve a tool" do
      klass = tool_class(:a)
      registry.register("a", klass)
      registry.register("b", optional: true) { :from_block }

      expect(registry.names).to contain_exactly("a", "b")
      entry_a = registry.entries.find { |e| e.name == "a" }
      expect(entry_a.factory.call).to eq(klass)
      expect(entry_a.optional).to be(false)
      expect(registry.entries.find { |e| e.name == "b" }.factory.call).to eq(:from_block)
    end
  end

  describe "#resolve (deprecated, paridade Fase 0)" do
    before do
      registry.register("a", tool_class(:a))                 # required
      registry.register("b", tool_class(:b), optional: true) # optional
    end

    it "required entra; optional sem opt-in fica de fora" do
      tools = silence_deprecation { registry.resolve(profile(tools_allow: nil)) }
      markers = tools.map { |t| t.new.marker }
      expect(markers).to eq([:a]) # b (optional) excluída
    end

    it "optional com opt-in entra" do
      tools = silence_deprecation { registry.resolve(profile(tools_allow: %w[a b])) }
      expect(tools.map { |t| t.new.marker }).to contain_exactly(:a, :b)
    end

    it "deny sempre vence" do
      tools = silence_deprecation { registry.resolve(profile(tools_allow: %w[a], tools_deny: %w[a])) }
      expect(tools).to eq([])
    end

    it "allow [] -> nenhuma tool (D6, divergência intencional da Fase 0)" do
      tools = silence_deprecation { registry.resolve(profile(tools_allow: [])) }
      expect(tools).to eq([])
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
