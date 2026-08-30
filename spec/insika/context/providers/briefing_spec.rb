# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Context::Providers::Briefing do
  let(:backend) { Insika::Stores::Memory.new }
  let(:sessions) { Insika::SessionStore.new(store: backend) }

  # Seeds the store with the given briefing (the provider reads the store, not
  # the request's session object) and returns the fresh Session.
  def seed(briefing)
    sessions.create(id: "s1")
    (briefing["fields"] || {}).each { |k, v| sessions.update_briefing("s1", field: k, value: v.to_s) }
    sessions.set_next_step("s1", text: briefing["next_step"]) if briefing["next_step"]
    sessions.find("s1")
  end

  def request(briefing: nil, declared: nil, session_id: "s1")
    profile = Insika::AgentProfile.build(id: "a", model: "m", briefing_fields: declared)
    session = briefing ? seed(briefing) : sessions.find(session_id)
    Insika::ContextRequest.new(session: session, message: "oi", profile: profile,
                                tenant: "acme", vars: {}, checkpoint: nil)
  end

  describe "#enabled_for?" do
    it "true when the pack declared fields" do
      provider = described_class.new(session_store: sessions)
      expect(provider.enabled_for?(request(declared: %w[size budget]).profile)).to be(true)
    end

    it "false when the pack declared nothing (nil or [])" do
      provider = described_class.new(session_store: sessions)
      expect(provider.enabled_for?(request(declared: nil).profile)).to be(false)
      expect(provider.enabled_for?(request(declared: []).profile)).to be(false)
    end
  end

  it "no session (one-shot turn) -> []" do
    profile = Insika::AgentProfile.build(id: "a", model: "m", briefing_fields: %w[size])
    req = Insika::ContextRequest.new(session: nil, message: "oi", profile: profile,
                                      tenant: "acme", vars: {}, checkpoint: nil)
    expect(described_class.new(session_store: sessions).call(req)).to eq([])
  end

  it "defensive: declared empty -> []" do
    expect(described_class.new(session_store: sessions).call(request(declared: []))).to eq([])
  end

  it "re-reads the briefing from the store, not the request's session snapshot" do
    briefing = { "fields" => { "size" => "M" }, "next_step" => nil }
    stale = Struct.new(:id, :briefing).new("s1", { "fields" => { "size" => "L" }, "next_step" => nil })
    req = Insika::ContextRequest.new(session: stale, message: "oi",
                                      profile: Insika::AgentProfile.build(id: "a", model: "m", briefing_fields: %w[size]),
                                      tenant: "acme", vars: {}, checkpoint: nil)
    seed(briefing)

    frags = described_class.new(session_store: sessions).call(req)
    expect(frags.first.content).to include("  size: M")
    expect(frags.first.content).not_to include("size: L")
  end

  it "splits into a durable HEAD block and a tail recitation" do
    briefing = { "fields" => { "size" => "M", "budget" => "400" },
                 "next_step" => "send the payment link tomorrow at 10" }
    head, tail = described_class.new(session_store: sessions)
                                 .call(request(briefing: briefing, declared: %w[size budget delivery_day]))

    expect([head.placement, head.priority, head.pinned]).to eq([:system, Insika::Context::Priority::BRIEFING, false])
    expect(head.source).to eq("briefing")
    expect(head.content).to eq(<<~BLOCK.strip)
      <briefing>
      known:
        size: M
        budget: 400
      </briefing>
    BLOCK

    expect([tail.placement, tail.priority, tail.pinned]).to eq([:tail, Insika::Context::Priority::RECITATION, false])
    expect(tail.source).to eq("briefing")
    expect(tail.content[:role]).to eq(:user)
    expect(tail.content[:content]).to eq(<<~BLOCK.strip)
      <recitation>
      still missing: delivery_day
      next step: send the payment link tomorrow at 10
      </recitation>
    BLOCK
  end

  it "the head never duplicates the recitation (no missing/next step in <briefing>)" do
    briefing = { "fields" => { "size" => "M" }, "next_step" => "close the order" }
    head, = described_class.new(session_store: sessions)
                            .call(request(briefing: briefing, declared: %w[size budget]))
    expect(head.content).not_to include("still missing")
    expect(head.content).not_to include("next step")
  end

  it "all-missing renders the recitation alone — no head block at all" do
    frags = described_class.new(session_store: sessions)
                            .call(request(briefing: { "fields" => {}, "next_step" => nil },
                                          declared: %w[size budget]))
    expect(frags.size).to eq(1)
    expect(frags.first.placement).to eq(:tail)
    expect(frags.first.content[:content]).to eq(<<~BLOCK.strip)
      <recitation>
      still missing: size, budget
      </recitation>
    BLOCK
  end

  it "everything known and no next step -> head only, no recitation" do
    briefing = { "fields" => { "size" => "M" }, "next_step" => nil }
    frags = described_class.new(session_store: sessions)
                            .call(request(briefing: briefing, declared: %w[size]))
    expect(frags.map(&:placement)).to eq([:system])
  end

  it "does not render stored keys that are NOT in the declaration (pack edited its schema)" do
    briefing = { "fields" => { "size" => "M", "vibe" => "x" }, "next_step" => nil }
    frags = described_class.new(session_store: sessions)
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
    frags = described_class.new(session_store: sessions)
                            .call(request(briefing: briefing, declared: %w[size vibe]))
    expect(frags.first.content).to include("  vibe: x")
  end

  it "a value with a newline is flattened so it cannot break the block's line structure" do
    briefing = { "fields" => { "size" => "M\nL" }, "next_step" => nil }
    frags = described_class.new(session_store: sessions)
                            .call(request(briefing: briefing, declared: %w[size budget]))
    expect(frags.first.content).to include("  size: M L")
  end

  it "uses the Priority::BRIEFING constant and pinned false" do
    briefing = { "fields" => { "size" => "M" }, "next_step" => nil }
    f = described_class.new(session_store: sessions)
                       .call(request(briefing: briefing, declared: %w[size budget])).first
    expect(f.priority).to eq(Insika::Context::Priority::BRIEFING)
    expect(f.pinned).to be(false)
  end
end