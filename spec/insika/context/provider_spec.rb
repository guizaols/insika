# frozen_string_literal: true

require "spec_helper"

#   — the layer contract. `layer` declares which cache layer a
# provider's output belongs to; :volatile is the conservative default so nothing
# gets pinned by accident.
RSpec.describe Insika::ContextProvider do
  it "defaults to :volatile (nothing gets pinned by accident)" do
    expect(described_class.new.layer).to eq(:volatile)
  end

  it "the three identity builtins override to :identity" do
    expect(Insika::Context::Providers::Prompt.new.layer).to eq(:identity)
    expect(Insika::Context::Providers::Skill.new(catalog: Insika::SkillCatalog.new([])).layer).to eq(:identity)
    expect(Insika::Context::Providers::ToolSearch.new(catalog: Insika::ToolCatalog.new(tool_registry: Insika::ToolRegistry.new)).layer).to eq(:identity)
  end

  it "the volatile builtins keep the base default" do
    expect(Insika::Context::Providers::Request.new.layer).to eq(:volatile)
    expect(Insika::Context::Providers::Session.new(session_store: Insika::SessionStore.new(store: Insika::Stores::Memory.new)).layer).to eq(:volatile)
    expect(Insika::Context::Providers::Memory.new(store: Insika::MemoryStore.new(store: Insika::Stores::Memory.new)).layer).to eq(:volatile)
    expect(Insika::Context::Providers::SkillTrigger.new(catalog: Insika::SkillCatalog.new([])).layer).to eq(:volatile)
  end
end
