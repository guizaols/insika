# frozen_string_literal: true

require "spec_helper"

# LLM-judge. Pure over an injected `ask` — no real LLM.
RSpec.describe Insika::Evals::Judge do
  def golden(expect)
    Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia",
                               "turns" => [{ "user" => "qual o frete?" }], "expect" => expect })
  end

  def result(text = "o frete é R$ 20 para SP capital")
    Insika::Evals::TurnResult.new(output_text: text, tool_calls: [], error: nil)
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

  # the judge's half of `policy`. How much a store wants its agent to
  # ask before acting is a per-store decision; a judge that is not TOLD it guesses,
  # and would be wrong for half the stores.
  describe "the store's policy in the prompt" do
    def prompt_for(expect)
      seen = nil
      described_class.new(ask: lambda { |p|
        seen = p
        '{"score": 1}'
      }).score(golden: golden(expect), result: result)
      seen
    end

    it "states the policy in the same words the deterministic layer checks" do
      prompt = prompt_for("rubric" => "x", "policy" => "ask_once")

      expect(prompt).to include("STORE POLICY")
      expect(prompt).to include("AT MOST ONE question per reply")
    end

    it "says nothing when the store has no opinion — a default would invent one" do
      expect(prompt_for("rubric" => "x")).not_to include("STORE POLICY")
    end
  end

  # `quorum` samples ONE model N times (its variance); a PANEL asks
  # different models (their disagreement), which is the signal worth having.
  describe "a panel of distinct judges" do
    def judge_of(*scores, **opts)
      asks = scores.map { |s| ->(_prompt) { %({"score": #{s}, "reason": "r#{s}"}) } }
      described_class.new(asks: asks, **opts)
    end

    let(:golden) { Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "a", "turns" => [{ "user" => "hi" }], "expect" => { "rubric" => "be kind", "min_score" => 0.7 } }) }
    let(:result) { Insika::Evals::TurnResult.new(output_text: "hello", tool_calls: [], error: nil) }

    it "keeps every judge's score visible instead of averaging it away" do
      verdict = judge_of(0.9, 0.4, 0.8).score(golden: golden, result: result)
      expect(verdict.judges).to eq([0.9, 0.4, 0.8])
    end

    it "aggregates the reported score (median by default)" do
      expect(judge_of(0.9, 0.4, 0.8).score(golden: golden, result: result).score).to eq(0.8)
      expect(judge_of(0.9, 0.4, 0.8, aggregate: :mean).score(golden: golden, result: result).score).to eq(0.7)
      expect(judge_of(0.9, 0.4, 0.8, aggregate: :min).score(golden: golden, result: result).score).to eq(0.4)
    end

    it "passes on a MAJORITY of judges by default (each against the case's min_score)" do
      expect(judge_of(0.9, 0.4, 0.8).score(golden: golden, result: result).pass).to be(true)  # 2 of 3
      expect(judge_of(0.9, 0.4, 0.4).score(golden: golden, result: result).pass).to be(false) # 1 of 3
    end

    it "min_agreement 1.0 demands unanimity — one dissenter fails the case" do
      verdict = judge_of(0.9, 0.8, 0.65, min_agreement: 1.0).score(golden: golden, result: result)
      expect([verdict.score, verdict.pass]).to eq([0.8, false])
    end

    it "a single ask still behaves exactly as before" do
      one = described_class.new(ask: ->(_p) { '{"score": 0.9, "reason": "ok"}' })
      verdict = one.score(golden: golden, result: result)
      expect([verdict.score, verdict.pass, verdict.judges]).to eq([0.9, true, [0.9]])
    end

    it "refuses to be built without a judge, and refuses an unknown aggregate" do
      expect { described_class.new(asks: []) }.to raise_error(ArgumentError, /at least one/)
      expect { described_class.new(ask: ->(_p) { "" }, aggregate: :vibes) }
        .to raise_error(ArgumentError, /unknown aggregate/)
    end
  end
end

