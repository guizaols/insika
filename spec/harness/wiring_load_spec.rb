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
end
