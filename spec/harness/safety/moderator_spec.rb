# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::Safety::Moderator do
  def moderator(reply)
    described_class.new(ask: ->(_prompt) { reply })
  end

  it "parses a refuse verdict" do
    v = moderator('{"category":"injection","action":"refuse","reason":"exfil"}').classify("x")
    expect(v.category).to eq("injection")
    expect(v.action).to eq("refuse")
    expect(v.block?).to be(true)
  end

  it "escalate is also a block" do
    expect(moderator('{"category":"abuse","action":"escalate"}').classify("x").block?).to be(true)
  end

  it "allow is not a block" do
    expect(moderator('{"category":"safe","action":"allow"}').classify("x").block?).to be(false)
  end

  it "extracts the JSON object even with surrounding prose" do
    v = moderator('Sure: {"category":"sexual","action":"refuse"} done').classify("x")
    expect(v.action).to eq("refuse")
  end

  it "fails OPEN on unparseable output (never blocks a legit customer on a bad reply)" do
    v = moderator("not json at all").classify("x")
    expect(v.action).to eq("allow")
    expect(v.block?).to be(false)
  end

  it "fails OPEN when the ask raises" do
    v = described_class.new(ask: ->(_p) { raise "provider down" }).classify("x")
    expect(v.action).to eq("allow")
  end

  it "coerces an unknown action/category to allow/safe (defensive)" do
    v = moderator('{"category":"weird","action":"nuke"}').classify("x")
    expect(v.action).to eq("allow")
    expect(v.category).to eq("safe")
  end
end
