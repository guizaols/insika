# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::Moderator do
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

  it "fails OPEN on unparseable output — unavailable, never a fake allow (RFC-0022)" do
    v = moderator("not json at all").classify("x")
    expect(v.action).to eq("unavailable")
    expect(v).to be_unavailable
    expect(v.block?).to be(false)
  end

  it "fails OPEN when the ask raises — unavailable, not a clean negative" do
    v = described_class.new(ask: ->(_p) { raise "provider down" }).classify("x")
    expect(v.action).to eq("unavailable")
    expect(v.block?).to be(false)
  end

  it "normalizes an out-of-enum action to unavailable (not an invented allow)" do
    v = moderator('{"category":"weird","action":"nuke"}').classify("x")
    expect(v.action).to eq("unavailable")
    expect(v.category).to eq("safe")
  end

  it "honors a literal unavailable action from the model" do
    v = moderator('{"category":"safe","action":"unavailable"}').classify("x")
    expect(v.action).to eq("unavailable")
    expect(v.block?).to be(false)
  end
end
