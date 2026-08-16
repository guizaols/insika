# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Briefing do
  def request(briefing: nil, declared: nil, session_id: "s1")
    profile = Insika::AgentProfile.build(id: "a", model: "m", briefing_fields: declared)
    session = Struct.new(:id, :briefing).new(session_id, briefing)
    Insika::ContextRequest.new(session: session, message: "oi", profile: profile,
                                tenant: "acme", vars: {}, checkpoint: nil)
  end

  describe "#enabled_for?" do
    it "true when the pack declared fields" do
      provider = described_class.new(session_store: nil)
      expect(provider.enabled_for?(request(declared: %w[size budget]).profile)).to be(true)
    end

    it "false when the pack declared nothing (nil or [])" do
      provider = described_class.new(session_store: nil)
      expect(provider.enabled_for?(request(declared: nil).profile)).to be(false)
      expect(provider.enabled_for?(request(declared: []).profile)).to be(false)
    end
  end

  it "no session (one-shot turn) -> []" do
    profile = Insika::AgentProfile.build(id: "a", model: "m", briefing_fields: %w[size])
    req = Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                      tenant: "acme", vars: {}, checkpoint: nil)
    expect(described_class.new(session_store: nil).call(req)).to eq([])
  end

  it "defensive: declared empty -> []" do
    expect(described_class.new(session_store: nil).call(request(declared: []))).to eq([])
  end

  it "renders known + still missing + next step in the exact block shape" do
    briefing = { "fields" => { "size" => "M", "budget" => "400" },
                 "next_step" => "send the payment link tomorrow at 10" }
    frags = described_class.new(session_store: nil)
                            .call(request(briefing: briefing, declared: %w[size budget delivery_day]))

    expect(frags.size).to eq(1)
    f = frags.first
    expect([f.placement, f.priority, f.pinned]).to eq([:system, Insika::Context::Priority::BRIEFING, false])
    expect(f.source).to eq("briefing")
    expect(f.content).to eq(<<~BLOCK.strip)
      <briefing>
      known:
        size: M
        budget: 400
      still missing: delivery_day
      next step: send the payment link tomorrow at 10
      </briefing>
    BLOCK
  end

  it "all-missing renders the missing list alone" do
    frags = described_class.new(session_store: nil)
                            .call(request(briefing: { "fields" => {}, "next_step" => nil },
                                          declared: %w[size budget]))
    expect(frags.first.content).to eq(<<~BLOCK.strip)
      <briefing>
      still missing: size, budget
      </briefing>
    BLOCK
  end

  it "does not render stored keys that are NOT in the declaration (pack edited its schema)" do
    briefing = { "fields" => { "size" => "M", "vibe" => "x" }, "next_step" => nil }
    frags = described_class.new(session_store: nil)
                            .call(request(briefing: briefing, declared: %w[size]))
    expect(frags.first.content).to eq(<<~BLOCK.strip)
      <briefing>
      known:
        size: M
      </briefing>
    BLOCK
  end

  it "a re-declared stored key reappears (schema edited back)" do
    briefing = { "fields" => { "size" => "M", "vibe" => "x" }, "next_step" => nil }
    frags = described_class.new(session_store: nil)
                            .call(request(briefing: briefing, declared: %w[size vibe]))
    expect(frags.first.content).to include("  vibe: x")
  end

  it "a value with a newline is flattened so it cannot break the block's line structure" do
    briefing = { "fields" => { "size" => "M\nL" }, "next_step" => nil }
    frags = described_class.new(session_store: nil)
                            .call(request(briefing: briefing, declared: %w[size budget]))
    expect(frags.first.content).to include("  size: M L")
  end

  it "uses the Priority::BRIEFING constant and pinned false" do
    briefing = { "fields" => { "size" => "M" }, "next_step" => nil }
    f = described_class.new(session_store: nil)
                       .call(request(briefing: briefing, declared: %w[size budget])).first
    expect(f.priority).to eq(Insika::Context::Priority::BRIEFING)
    expect(f.pinned).to be(false)
  end
end