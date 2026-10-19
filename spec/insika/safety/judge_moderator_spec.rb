# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Safety::JudgeModerator do
  def judge_returning(category, confidence)
    ->(_message) { { "category" => category, "confidence" => confidence } }
  end

  let(:fallback) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = 0

      def classify(_message, context: nil)
        @calls += 1
        Insika::Safety::Moderator::Verdict.new(category: "safe", action: "allow", reason: "fallback")
      end
    end.new
  end

  it "refuses a confident injection without calling the fallback" do
    v = described_class.new(judge: judge_returning("injection", 0.95), fallback: fallback).classify("x")
    expect(v.action).to eq("refuse")
    expect(v.category).to eq("injection")
    expect(fallback.calls).to eq(0)
  end

  it "escalates confident abuse and self_harm" do
    %w[abuse self_harm].each do |cat|
      expect(described_class.new(judge: judge_returning(cat, 0.9)).classify("x").action).to eq("escalate")
    end
  end

  it "allows a confident safe or off_topic message without calling the fallback" do
    %w[safe off_topic].each do |cat|
      v = described_class.new(judge: judge_returning(cat, 0.9), fallback: fallback).classify("x")
      expect(v.action).to eq("allow")
    end
    expect(fallback.calls).to eq(0)
  end

  it "hands a low-confidence judgment to the fallback" do
    v = described_class.new(judge: judge_returning("sexual", 0.5), fallback: fallback).classify("x")
    expect(v.reason).to eq("fallback")
    expect(fallback.calls).to eq(1)
  end

  it "hands a judge error to the fallback" do
    v = described_class.new(judge: ->(_m) { raise "typesafe down" }, fallback: fallback).classify("x")
    expect(v.reason).to eq("fallback")
  end

  it "fails open as unavailable when the judge errors and there is no fallback" do
    v = described_class.new(judge: ->(_m) { raise "typesafe down" }).classify("x")
    expect(v).to be_unavailable
    expect(v.block?).to be(false)
  end

  it "is unavailable when low confidence and no fallback (never a fake allow)" do
    v = described_class.new(judge: judge_returning("injection", 0.4)).classify("x")
    expect(v).to be_unavailable
  end

  it "treats an unknown category as low confidence" do
    v = described_class.new(judge: judge_returning("weird", 0.99), fallback: fallback).classify("x")
    expect(fallback.calls).to eq(1)
    expect(v.reason).to eq("fallback")
  end

  it "declares one choice question over exactly the moderator categories" do
    q = described_class::QUESTION.fetch("category")
    expect(q[:type]).to eq(:choice)
    expect(q[:options].keys).to match_array(Insika::Safety::Moderator::CATEGORIES)
  end
end
