# frozen_string_literal: true

require "spec_helper"
require_relative "../../config/wiring" # composition root real (constrói o grafo eager)

# Guard de carga do composition root (P2B task 11): a fatia B acrescentou
# CAPABILITY_REGISTRY + TOOL_CATALOG e o Context::Providers::ToolSearch — este
# spec trava que o wiring real ainda constrói sem erro com essas adições.
RSpec.describe Harness::Wiring do
  it "constrói CAPABILITY_REGISTRY e TOOL_CATALOG" do
    expect(described_class::CAPABILITY_REGISTRY).to be_a(Harness::CapabilityRegistry)
    expect(described_class::TOOL_CATALOG).to be_a(Harness::ToolCatalog)
  end

  it "inclui o Context::Providers::ToolSearch no CONTEXT_PROVIDERS" do
    expect(described_class::CONTEXT_PROVIDERS).to include(a_kind_of(Harness::Context::Providers::ToolSearch))
  end

  it "EXECUTOR construído sem ArgumentError (kwargs capability_registry/tool_catalog aceitos)" do
    expect(described_class::EXECUTOR).to be_a(Harness::Executor)
  end

  it "constrói MEMORY_STORE e inclui o Memory provider no CONTEXT_PROVIDERS (P2C)" do
    expect(described_class::MEMORY_STORE).to be_a(Harness::MemoryStore)
    expect(described_class::CONTEXT_PROVIDERS).to include(a_kind_of(Harness::Context::Providers::Memory))
  end

  it "A2A_APP é nil por default (opt-in; PROFILES vazio na base) e o APP constrói (P3A)" do
    expect(described_class::A2A_APP).to be_nil # sem HARNESS_A2A_AGENT / PROFILES vazio
    expect(described_class::APP).to be_a(Harness::Server::App) # aceita a2a: nil
  end

  it "A2A_CLIENT construído; sem HARNESS_A2A_REMOTES nenhum tool remote_* registrado (P3B)" do
    expect(described_class::A2A_CLIENT).to be_a(Harness::Server::A2A::Client)
    expect(described_class::REGISTRY.names.grep(/^remote_/)).to eq([])
  end
end
