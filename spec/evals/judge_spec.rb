# frozen_string_literal: true

require "spec_helper"
require_relative "../../evals/lib/evals/golden"
require_relative "../../evals/lib/evals/assertions"
require_relative "../../evals/lib/evals/judge"

# LLM-judge (RFC-0008 §3.3, Fase B). Pure over an injected `ask` — no real LLM.
RSpec.describe Evals::Judge do
  def golden(expect)
    Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia",
                               "turns" => [{ "user" => "qual o frete?" }], "expect" => expect })
  end

  def result(text = "o frete é R$ 20 para SP capital")
    Evals::TurnResult.new(output_text: text, tool_calls: [], error: nil)
  end

  it "returns nil when there is no rubric to score" do
    j = described_class.new(ask: ->(_p) { '{"score":1}' })
    expect(j.score(golden: golden({}), result: result)).to be_nil
  end

  it "passes when the score meets the golden's min_score" do
    j = described_class.new(ask: ->(_p) { '{"score": 0.9, "reason": "cotou certo"}' })
    v = j.score(golden: golden("rubric" => "cote o frete", "min_score" => 0.7), result: result)
    expect(v.score).to eq(0.9)
    expect(v.pass).to be(true)
    expect(v.reason).to eq("cotou certo")
  end

  it "fails when the score is below min_score" do
    j = described_class.new(ask: ->(_p) { '{"score": 0.4, "reason": "inventou prazo"}' })
    v = j.score(golden: golden("rubric" => "sem inventar prazo", "min_score" => 0.7), result: result)
    expect(v.pass).to be(false)
  end

  it "defaults min_score to 0.7 when the golden omits it" do
    j = described_class.new(ask: ->(_p) { '{"score": 0.7}' })
    expect(j.score(golden: golden("rubric" => "x"), result: result).pass).to be(true)
  end

  it "extracts the JSON even when the model wraps it in prose" do
    j = described_class.new(ask: ->(_p) { "Sure!\n{\"score\": 0.8, \"reason\": \"ok\"}\nHope that helps" })
    expect(j.score(golden: golden("rubric" => "x"), result: result).score).to eq(0.8)
  end

  it "scores an unparseable reply as 0 (fails) — never a silent pass" do
    j = described_class.new(ask: ->(_p) { "the model rambled with no json" })
    v = j.score(golden: golden("rubric" => "x"), result: result)
    expect(v.score).to eq(0.0)
    expect(v.pass).to be(false)
    expect(v.reason).to match(/unparseable/)
  end

  it "clamps an out-of-range score into [0,1]" do
    j = described_class.new(ask: ->(_p) { '{"score": 4.2}' })
    expect(j.score(golden: golden("rubric" => "x"), result: result).score).to eq(1.0)
  end

  it "takes the MEDIAN across a quorum (blunts single-shot flakiness)" do
    scores = [0.2, 0.9, 0.8].each
    j = described_class.new(ask: ->(_p) { %({"score": #{scores.next}}) }, quorum: 3)
    # median(0.2, 0.9, 0.8) = 0.8 -> passes at 0.7
    expect(j.score(golden: golden("rubric" => "x"), result: result).pass).to be(true)
  end
end
