# frozen_string_literal: true

require "spec_helper"
require_relative "../../config/wiring" # real composition root (builds the eager graph)

# Load guard for the composition root: added
# CAPABILITY_REGISTRY + TOOL_CATALOG and Context::Providers::ToolSearch — this
# spec locks that the real wiring still builds without error with these additions.
RSpec.describe Insika::Wiring do
  it "builds CAPABILITY_REGISTRY and TOOL_CATALOG" do
    expect(described_class::CAPABILITY_REGISTRY).to be_a(Insika::CapabilityRegistry)
    expect(described_class::TOOL_CATALOG).to be_a(Insika::ToolCatalog)
  end

  it "includes Context::Providers::ToolSearch in CONTEXT_PROVIDERS" do
    expect(described_class::CONTEXT_PROVIDERS).to include(a_kind_of(Insika::Context::Providers::ToolSearch))
  end

  it "EXECUTOR built without ArgumentError (capability_registry/tool_catalog kwargs accepted)" do
    expect(described_class::EXECUTOR).to be_a(Insika::Executor)
  end

  it "builds MEMORY_STORE and includes the Memory provider in CONTEXT_PROVIDERS" do
    expect(described_class::MEMORY_STORE).to be_a(Insika::MemoryStore)
    expect(described_class::CONTEXT_PROVIDERS).to include(a_kind_of(Insika::Context::Providers::Memory))
  end

  it "includes the Briefing provider  in CONTEXT_PROVIDERS, before Session" do
    providers = described_class::CONTEXT_PROVIDERS
    expect(providers).to include(a_kind_of(Insika::Context::Providers::Briefing))
    expect(providers.index { |p| p.is_a?(Insika::Context::Providers::Briefing) })
      .to be < providers.index { |p| p.is_a?(Insika::Context::Providers::Session) }
  end

  it "A2A_APP is nil by default (opt-in; empty PROFILES at the base) and the APP builds" do
    expect(described_class::A2A_APP).to be_nil # no INSIKA_A2A_AGENT / empty PROFILES
    expect(described_class::APP).to be_a(Insika::Server::App) # aceita a2a: nil
  end

  it "A2A_CLIENT built; without INSIKA_A2A_REMOTES no remote_* tool is registered" do
    expect(described_class::A2A_CLIENT).to be_a(Insika::Server::A2A::Client)
    expect(described_class::REGISTRY.names.grep(/^remote_/)).to eq([])
  end
end
