# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Registry do
  subject(:registry) { described_class.new }

  it "duplicate: first wins, second discarded with warn" do
    registry.register("a", :primeiro, plugin: "p1")
    expect { registry.register("a", :segundo, plugin: "p2") }.to output(/already registered/).to_stderr
    expect(registry.resolve("a")).to eq(:primeiro)
    expect(registry.entries.size).to eq(1)
  end

  it "resolve nonexistent -> NotFoundError" do
    expect { registry.resolve("nope") }.to raise_error(Insika::NotFoundError)
  end

  it "factory via positional callable" do
    klass = Class.new
    registry.register("a", klass)
    expect(registry.resolve("a")).to eq(klass)
  end

  it "factory via block: invokes the block on each resolve" do
    n = 0
    registry.register("a") { n += 1 }
    registry.resolve("a")
    registry.resolve("a")
    expect(n).to eq(2)
  end

  it "metadata preserved (Symbol keys) + plugin" do
    registry.register("a", :x, plugin: "p", foo: 1, bar: 2)
    entry = registry.entries.first
    expect(entry.metadata).to eq({ foo: 1, bar: 2 })
    expect(entry.plugin).to eq("p")
  end

  it "register without factory (callable and block absent) -> ArgumentError" do
    expect { registry.register("a") }.to raise_error(ArgumentError)
  end

  it "names and entries" do
    registry.register("a", :x)
    registry.register("b", :y)
    expect(registry.names).to eq(%w[a b])
    expect(registry.entries).to all(be_a(described_class::Entry))
  end

  it "normalizes Symbol names at the boundary" do
    registry.register(:foo, :x)
    expect(registry.resolve(:foo)).to eq(:x)
  end

  it "deregister_plugin removes only the plugin's entries" do
    registry.register("a", :x, plugin: "keep")
    registry.register("b", :y, plugin: "drop")
    registry.register("c", :z, plugin: "drop")
    registry.deregister_plugin("drop")
    expect(registry.names).to eq(["a"])
  end

  it "deregister_plugin of a plugin without entries is a no-op" do
    registry.register("a", :x, plugin: "keep")
    expect { registry.deregister_plugin("missing") }.not_to raise_error
    expect(registry.names).to eq(["a"])
  end
end
