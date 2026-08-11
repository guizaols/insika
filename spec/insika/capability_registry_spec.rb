# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::CapabilityRegistry do
  subject(:registry) { described_class.new }

  # Minimal profile: `resolve` only reads `tools_deny` (deny-only,/L3). `tools_allow`
  # exists to prove it is IGNORED during resolution.
  ProfileDouble = Struct.new(:tools_deny, :tools_allow) do
    def self.with(deny: [], allow: nil) = new(deny, allow)
  end

  # Event Stream spy: collects what was emitted (duck-type `emit`).
  class EventSpy
    attr_reader :events

    def initialize = @events = []
    def emit(event) = @events << event
  end

  def profile(deny: [], allow: nil) = ProfileDouble.with(deny: deny, allow: allow)

  describe "#register / #providers / #capabilities" do
    it "stores candidates in registration order (no 'first wins')" do
      registry.register(:browse, impl_name: "b1", kind: :tool, plugin: "a")
      registry.register(:browse, impl_name: "b2", kind: :tool, plugin: "b")
      expect(registry.providers(:browse).map(&:impl_name)).to eq(%w[b1 b2])
    end

    it "capabilities lists only the registered ones" do
      registry.register(:browse, impl_name: "b1", kind: :tool)
      registry.register(:search, impl_name: "s1", kind: :tool)
      expect(registry.capabilities).to contain_exactly(:browse, :search)
    end

    it "invalid kind -> ArgumentError" do
      expect { registry.register(:x, impl_name: "i", kind: :foo) }.to raise_error(ArgumentError)
    end

    it "kind :workflow registers but warns (deferred exposure, L5)" do
      expect do
        registry.register(:research, impl_name: "r", kind: :workflow)
      end.to output(/workflow/).to_stderr
      expect(registry.providers(:research).map(&:impl_name)).to eq(["r"])
    end
  end

  describe "#resolve — availability and deny" do
    it "resolves to the one with the highest priority" do
      registry.register(:browse, impl_name: "lo", kind: :tool, priority: 50)
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("hi")
    end

    it "discards available? == false before tie-breaking" do
      registry.register(:browse, impl_name: "off", kind: :tool, priority: 100, available: -> { false })
      registry.register(:browse, impl_name: "on", kind: :tool, priority: 50)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("on")
    end

    it "tools_deny removes the impl_name (deny wins), possibly emptying -> Unavailable" do
      registry.register(:browse, impl_name: "only", kind: :tool, priority: 100)
      expect do
        registry.resolve(:browse, profile: profile(deny: ["only"]))
      end.to raise_error(Insika::CapabilityUnavailable)
    end

    it "tools_allow does NOT filter candidates (deny-only,/L3)" do
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      registry.register(:browse, impl_name: "lo", kind: :tool, priority: 50)
      # allow lists only "lo"; still resolves to "hi" (allow is ignored)
      expect(registry.resolve(:browse, profile: profile(allow: ["lo"])).impl_name).to eq("hi")
    end

    it "0 candidates (capability never registered) -> Unavailable" do
      expect do
        registry.resolve(:nope, profile: profile)
      end.to raise_error(Insika::CapabilityUnavailable)
    end
  end

  describe "#resolve — tie-break by plugin precedence" do
    it "different plugins, same priority -> first registered wins" do
      registry.register(:browse, impl_name: "from_a", kind: :tool, plugin: "a", priority: 100)
      registry.register(:browse, impl_name: "from_b", kind: :tool, plugin: "b", priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("from_a")
    end

    it "same plugin, same priority -> Ambiguous with the candidates" do
      registry.register(:browse, impl_name: "x", kind: :tool, plugin: "same", priority: 100)
      registry.register(:browse, impl_name: "y", kind: :tool, plugin: "same", priority: 100)
      expect do
        registry.resolve(:browse, profile: profile)
      end.to raise_error(Insika::CapabilityAmbiguous) { |e| expect(e.candidates.size).to eq(2) }
    end

    it "nil vs named plugin, same priority -> not ambiguous (registration order)" do
      registry.register(:browse, impl_name: "no_plugin", kind: :tool, plugin: nil, priority: 100)
      registry.register(:browse, impl_name: "named", kind: :tool, plugin: "a", priority: 100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("no_plugin")
    end

    it "nil vs nil plugin, same priority -> Ambiguous" do
      registry.register(:browse, impl_name: "n1", kind: :tool, plugin: nil, priority: 100)
      registry.register(:browse, impl_name: "n2", kind: :tool, plugin: nil, priority: 100)
      expect do
        registry.resolve(:browse, profile: profile)
      end.to raise_error(Insika::CapabilityAmbiguous)
    end
  end

  describe "#resolve — priority nil" do
    it "priority nil loses to explicit negative priority" do
      registry.register(:browse, impl_name: "nil_prio", kind: :tool, priority: nil)
      registry.register(:browse, impl_name: "neg", kind: :tool, priority: -100)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("neg")
    end

    it "two nils (different plugins) tie-break by registration order" do
      registry.register(:browse, impl_name: "first", kind: :tool, plugin: "a", priority: nil)
      registry.register(:browse, impl_name: "second", kind: :tool, plugin: "b", priority: nil)
      expect(registry.resolve(:browse, profile: profile).impl_name).to eq("first")
    end
  end

  describe "#resolve — event" do
    it "emits :capability_resolved with capability/chosen/candidates" do
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

    it "without event_stream it neither raises nor emits" do
      registry.register(:browse, impl_name: "hi", kind: :tool, priority: 100)
      expect { registry.resolve(:browse, profile: profile, event_stream: nil) }.not_to raise_error
    end
  end

  describe "#deregister_plugin" do
    it "removes only the plugin's providers; a capability with no providers disappears" do
      registry.register(:browse, impl_name: "keep", kind: :tool, plugin: "keep")
      registry.register(:browse, impl_name: "drop", kind: :tool, plugin: "drop")
      registry.register(:search, impl_name: "gone", kind: :tool, plugin: "drop")
      registry.deregister_plugin("drop")
      expect(registry.providers(:browse).map(&:impl_name)).to eq(["keep"])
      expect(registry.capabilities).to eq([:browse])
    end

    it "plugin with no providers is a no-op" do
      registry.register(:browse, impl_name: "x", kind: :tool, plugin: "keep")
      expect { registry.deregister_plugin("missing") }.not_to raise_error
      expect(registry.capabilities).to eq([:browse])
    end
  end
end
