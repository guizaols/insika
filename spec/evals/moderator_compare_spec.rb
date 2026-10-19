# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Evals::ModeratorCompare do
  def fake(actions)
    Class.new do
      define_method(:classify) do |message, context: nil|
        Insika::Safety::Moderator::Verdict.new(category: "x", action: actions.fetch(message), reason: "")
      end
    end.new
  end

  let(:cases) do
    [
      { "id" => "a", "message" => "m1", "expected" => "allow" },
      { "id" => "b", "message" => "m2", "expected" => "refuse" },
      { "id" => "c", "message" => "m3", "expected" => "allow" },
      { "id" => "d", "message" => "m4", "expected" => "escalate" }
    ]
  end

  it "counts correct, false blocks, missed blocks and unavailable" do
    mod = fake("m1" => "allow", "m2" => "allow", "m3" => "refuse", "m4" => "refuse")
    r = described_class.new(moderators: { "judge" => mod }).run(cases)["judge"]
    expect(r.values_at("correct", "total", "false_blocks", "missed_blocks")).to eq([2, 4, 1, 1])
    expect(r["misses"]).to eq(%w[b c])
  end

  it "never counts unavailable as a correct allow" do
    mod = fake("m1" => "unavailable", "m2" => "refuse", "m3" => "allow", "m4" => "escalate")
    r = described_class.new(moderators: { "judge" => mod }).run(cases)["judge"]
    expect(r["unavailable"]).to eq(1)
    expect(r["correct"]).to eq(3)
  end

  it "reports latency percentiles" do
    mod = fake("m1" => "allow", "m2" => "refuse", "m3" => "allow", "m4" => "escalate")
    r = described_class.new(moderators: { "judge" => mod }).run(cases)["judge"]
    expect(r["p50_ms"]).to be_a(Numeric)
    expect(r["p95_ms"]).to be >= r["p50_ms"]
  end
end
