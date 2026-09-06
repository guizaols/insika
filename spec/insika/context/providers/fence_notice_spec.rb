# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::FenceNotice do
  def profile(fencing: nil) = Insika::AgentProfile.build(id: "a", model: "m", fencing: fencing)

  def request(prof)
    Insika::ContextRequest.new(session: nil, message: "oi", profile: prof, tenant: nil, vars: {}, checkpoint: nil)
  end

  it "is not governed by the context_providers allowlist (the fencing flag is the opt-in)" do
    expect(described_class.new.allowlisted?).to be(false)
  end

  it "fencing off (the default) -> not enabled, produces nothing" do
    expect(described_class.new.enabled_for?(profile)).to be(false)
  end

  it "fencing on -> ONE pinned :system fragment in the identity layer, right under the identity" do
    provider = described_class.new
    expect(provider.enabled_for?(profile(fencing: true))).to be(true)
    expect(provider.layer).to eq(:identity)

    frags = provider.call(request(profile(fencing: true)))
    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.pinned, f.priority]).to eq([:system, true, Insika::Context::Priority::FENCE_NOTICE])
    expect(f.priority).to be < Insika::Context::Priority::IDENTITY
    expect(f.priority).to be > Insika::Context::Priority::PROMPT_REF
    expect(f.content).to eq(described_class::NOTICE)
  end

  it "byte-stable across turns and requests (the cache-boundary contract)" do
    provider = described_class.new
    a = provider.call(request(profile(fencing: true))).first.content
    b = provider.call(request(profile(fencing: true))).first.content
    expect(a).to eq(b)
    expect(a).to include("<memory>", "<knowledge>", "<briefing>", "<conversation_summary>", "every tool result")
  end
end
