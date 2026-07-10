# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Registry do
  subject(:registry) { described_class.new }

  it "duplicata: primeiro vence, segundo descartado com warn" do
    registry.register("a", :primeiro, plugin: "p1")
    expect { registry.register("a", :segundo, plugin: "p2") }.to output(/já registrada/).to_stderr
    expect(registry.resolve("a")).to eq(:primeiro)
    expect(registry.entries.size).to eq(1)
  end

  it "resolve inexistente -> NotFoundError" do
    expect { registry.resolve("nope") }.to raise_error(Harness::NotFoundError)
  end

  it "factory por callable posicional" do
    klass = Class.new
    registry.register("a", klass)
    expect(registry.resolve("a")).to eq(klass)
  end

  it "factory por bloco: invoca o bloco a cada resolve" do
    n = 0
    registry.register("a") { n += 1 }
    registry.resolve("a")
    registry.resolve("a")
    expect(n).to eq(2)
  end

  it "metadata preservada (chaves Symbol) + plugin" do
    registry.register("a", :x, plugin: "p", foo: 1, bar: 2)
    entry = registry.entries.first
    expect(entry.metadata).to eq({ foo: 1, bar: 2 })
    expect(entry.plugin).to eq("p")
  end

  it "register sem factory (callable e bloco ausentes) -> ArgumentError" do
    expect { registry.register("a") }.to raise_error(ArgumentError)
  end

  it "names e entries" do
    registry.register("a", :x)
    registry.register("b", :y)
    expect(registry.names).to eq(%w[a b])
    expect(registry.entries).to all(be_a(described_class::Entry))
  end

  it "normaliza nomes Symbol na borda" do
    registry.register(:foo, :x)
    expect(registry.resolve(:foo)).to eq(:x)
  end

  it "deregister_plugin remove só as entries do plugin" do
    registry.register("a", :x, plugin: "keep")
    registry.register("b", :y, plugin: "drop")
    registry.register("c", :z, plugin: "drop")
    registry.deregister_plugin("drop")
    expect(registry.names).to eq(["a"])
  end

  it "deregister_plugin de plugin sem entries é no-op" do
    registry.register("a", :x, plugin: "keep")
    expect { registry.deregister_plugin("ausente") }.not_to raise_error
    expect(registry.names).to eq(["a"])
  end
end
