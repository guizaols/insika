# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::CapabilityRegistry do
  subject(:registry) { described_class.new }

  # Profile mínimo: `resolve` só lê `tools_deny` (deny-only, D3/L3). `tools_allow`
  # existe para provar que é IGNORADO na resolução.
  ProfileDouble = Struct.new(:tools_deny, :tools_allow) do
    def self.with(deny: [], allow: nil) = new(deny, allow)
  end

  # Spy de Event Stream: coleta o que foi emitido (duck-type `emit`).
  class EventSpy
    attr_reader :events

    def initialize = @events = []
    def emit(event) = @events << event
  end

  def profile(deny: [], allow: nil) = ProfileDouble.with(deny: deny, allow: allow)

  describe "#register / #providers / #capabilities" do
    it "guarda candidatos na ordem de registro (sem 'primeiro vence')" do
      registry.register(:browse, impl_name: "b1", kind: :tool, plugin: "a")
      registry.register(:browse, impl_name: "b2", kind: :tool, plugin: "b")
      expect(registry.providers(:browse).map(&:impl_name)).to eq(%w[b1 b2])
    end

    it "capabilities lista só as registradas" do
      registry.register(:browse, impl_name: "b1", kind: :tool)
      registry.register(:search, impl_name: "s1", kind: :tool)
      expect(registry.capabilities).to contain_exactly(:browse, :search)
    end

    it "kind inválido -> ArgumentError" do
      expect { registry.register(:x, impl_name: "i", kind: :foo) }.to raise_error(ArgumentError)
    end

    it "kind :workflow registra mas avisa (exposição adiada, L5)" do
      expect do
        registry.register(:research, impl_name: "r", kind: :workflow)
      end.to output(/workflow/).to_stderr
      expect(registry.providers(:research).map(&:impl_name)).to eq(["r"])
    end
  end

  describe "#resolve — disponibilidade e deny" do
    it "resolve para o de maior priority" do
      registry.register(:browse, impl_name: "lo", kind: :tool, priority: 50)
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("hi")
    end

    it "descarta available? == false antes do desempate" do
      registry.register(:browse, impl_name: "off", kind: :tool, priority: 100, available: -> { false })
      registry.register(:browse, impl_name: "on", kind: :tool, priority: 50)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("on")
    end

    it "tools_deny remove o impl_name (deny vence), podendo zerar -> Unavailable" do
      registry.register(:browse, impl_name: "only", kind: :tool, priority: 100)
      expect do
        registry.resolve(:browse, profile: profile(deny: ["only"]))
      end.to raise_error(Harness::CapabilityUnavailable)
    end

    it "tools_allow NÃO filtra candidatos (deny-only, D3/L3)" do
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      registry.register(:browse, impl_name: "lo", kind: :tool, priority: 50)
      # allow lista só "lo"; ainda assim resolve para "hi" (allow é ignorado)
      expect(registry.resolve(:browse, profile: profile(allow: ["lo"])).impl_name).to eq("hi")
    end

    it "0 candidatos (capability nunca registrada) -> Unavailable" do
      expect do
        registry.resolve(:nope, profile: profile)
      end.to raise_error(Harness::CapabilityUnavailable)
    end
  end

  describe "#resolve — desempate por precedência de plugin" do
    it "plugins diferentes, mesma priority -> primeiro registrado vence" do
      registry.register(:browse, impl_name: "from_a", kind: :tool, plugin: "a", priority: 100)
      registry.register(:browse, impl_name: "from_b", kind: :tool, plugin: "b", priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("from_a")
    end

    it "mesmo plugin, mesma priority -> Ambiguous com os candidatos" do
      registry.register(:browse, impl_name: "x", kind: :tool, plugin: "same", priority: 100)
      registry.register(:browse, impl_name: "y", kind: :tool, plugin: "same", priority: 100)
      expect do
        registry.resolve(:browse, profile: profile)
      end.to raise_error(Harness::CapabilityAmbiguous) { |e| expect(e.candidates.size).to eq(2) }
    end

    it "nil vs plugin nomeado, mesma priority -> não é ambíguo (ordem de registro)" do
      registry.register(:browse, impl_name: "no_plugin", kind: :tool, plugin: nil, priority: 100)
      registry.register(:browse, impl_name: "named", kind: :tool, plugin: "a", priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("no_plugin")
    end

    it "nil vs nil de plugin, mesma priority -> Ambiguous" do
      registry.register(:browse, impl_name: "n1", kind: :tool, plugin: nil, priority: 100)
      registry.register(:browse, impl_name: "n2", kind: :tool, plugin: nil, priority: 100)
      expect do
        registry.resolve(:browse, profile: profile)
      end.to raise_error(Harness::CapabilityAmbiguous)
    end
  end

  describe "#resolve — priority nil" do
    it "priority nil perde para priority negativa explícita" do
      registry.register(:browse, impl_name: "nil_prio", kind: :tool, priority: nil)
      registry.register(:browse, impl_name: "neg", kind: :tool, priority: -100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("neg")
    end

    it "dois nil (plugins diferentes) desempatam por ordem de registro" do
      registry.register(:browse, impl_name: "first", kind: :tool, plugin: "a", priority: nil)
      registry.register(:browse, impl_name: "second", kind: :tool, plugin: "b", priority: nil)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("first")
    end
  end

  describe "#resolve — evento" do
    it "emite :capability_resolved com capability/chosen/candidates" do
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      registry.register(:browse, impl_name: "lo", kind: :tool, priority: 50)
      spy = EventSpy.new
      registry.resolve(:browse, profile: profile, event_stream: spy)
      event = spy.events.first
      expect(event.type).to eq(:capability_resolved)
      expect(event.data[:capability]).to eq(:browse)
      expect(event.data[:chosen]).to eq("hi")
      expect(event.data[:candidates].map { |c| c[:impl_name] }).to eq(%w[hi lo])
    end

    it "sem event_stream não levanta nem emite" do
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      expect { registry.resolve(:browse, profile: profile, event_stream: nil) }.not_to raise_error
    end
  end

  describe "#deregister_plugin" do
    it "remove só os providers do plugin; capability sem providers some" do
      registry.register(:browse, impl_name: "keep", kind: :tool, plugin: "keep")
      registry.register(:browse, impl_name: "drop", kind: :tool, plugin: "drop")
      registry.register(:search, impl_name: "gone", kind: :tool, plugin: "drop")
      registry.deregister_plugin("drop")
      expect(registry.providers(:browse).map(&:impl_name)).to eq(["keep"])
      expect(registry.capabilities).to eq([:browse])
    end

    it "plugin sem providers é no-op" do
      registry.register(:browse, impl_name: "x", kind: :tool, plugin: "keep")
      expect { registry.deregister_plugin("ausente") }.not_to raise_error
      expect(registry.capabilities).to eq([:browse])
    end
  end
end
