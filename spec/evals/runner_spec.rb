# frozen_string_literal: true

require "spec_helper"

# Runner orchestration (RFC-0008). Pure over the Transport — a fake makes the
# replay/evaluate loop testable offline, no server or LLM.
RSpec.describe Insika::Evals::Runner do
  # Returns a scripted TurnResult per message; records the messages it saw.
  class FakeTransport
    attr_reader :seen

    def initialize(&script)
      @script = script
      @seen = []
    end

    def turn(agent:, conv:, message:)
      @seen << { agent: agent, conv: conv, message: message }
      Insika::Evals::TurnOutcome.new(result: @script.call(message), ttfb: 1.0, total: 2.0)
    end
  end

  def golden(overrides = {})
    Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia",
                                "turns" => [{ "user" => "oi" }], "expect" => {} }.merge(overrides))
  end

  def ok_result(tools = [])
    Insika::Evals::TurnResult.new(output_text: "ok", tool_calls: tools, error: nil)
  end

  it "replays a single turn and evaluates it" do
    t = FakeTransport.new { ok_result([{ "name" => "shipping_quote" }]) }
    rc = described_class.new(transport: t).run_case(golden("expect" => { "tools_called" => ["shipping_quote"] }))
    expect(rc.result.pass?).to be(true)
    expect(rc.timings.size).to eq(1)
    expect(t.seen.first[:conv]).to eq("eval-c")
  end

  it "replays multi-turn IN ORDER under one conv id and asserts on the LAST turn" do
    g = golden("turns" => [{ "user" => "oi" }, { "user" => "qual o frete?" }],
               "expect" => { "tools_called" => ["shipping_quote"] })
    # only the 2nd turn calls the tool — the case passes because the assert is on the last result
    t = FakeTransport.new { |msg| msg.include?("frete") ? ok_result([{ "name" => "shipping_quote" }]) : ok_result }
    rc = described_class.new(transport: t).run_case(g)
    expect(rc.result.pass?).to be(true)
    expect(t.seen.map { |s| s[:message] }).to eq(["oi", "qual o frete?"])
    expect(t.seen.map { |s| s[:conv] }.uniq).to eq(["eval-c"])
  end

  # The tool/content assertions read the last turn; the policy checks read every one.
  # "at most one question per reply" is a rule about EACH reply, and the violation the
  # feature exists for was on turn 1 — evaluating only the last one would miss it.
  it "hands EVERY turn to the policy checks, not just the last" do
    g = golden("turns" => [{ "user" => "oi" }, { "user" => "e aí?" }],
               "expect" => { "policy" => "ask_once" })
    t = FakeTransport.new do |msg|
      msg == "oi" ? Insika::Evals::TurnResult.new(output_text: "pra você ou presente? qual tamanho?",
                                                  tool_calls: [], error: nil) : ok_result
    end

    rc = described_class.new(transport: t).run_case(g)

    expect(rc.result.pass?).to be(false)
    expect(rc.result.failures.first.detail).to include("turn 1")
  end

  it "aborts the conversation on a turn error and fails the case" do
    g = golden("turns" => [{ "user" => "a" }, { "user" => "b" }])
    t = FakeTransport.new { Insika::Evals::TurnResult.new(output_text: "", tool_calls: [], error: "timeout") }
    rc = described_class.new(transport: t).run_case(g)
    expect(rc.result.pass?).to be(false)
    expect(rc.result.error).to eq("timeout")
    expect(t.seen.size).to eq(1) # never sent the 2nd turn
  end

  it "runs a whole set" do
    t = FakeTransport.new { ok_result }
    results = described_class.new(transport: t).run([golden, golden("id" => "c2")])
    expect(results.size).to eq(2)
    expect(results).to all(be_a(Insika::Evals::Runner::RunCase))
  end

  # A judge stub: records whether it was asked, returns a scripted verdict.
  class FakeJudge
    Verdict = Struct.new(:score, :pass, :reason, keyword_init: true)
    attr_reader :calls

    def initialize(pass:)
      @pass = pass
      @calls = 0
    end

    def score(golden:, result:)
      @calls += 1
      Verdict.new(score: @pass ? 0.9 : 0.3, pass: @pass, reason: "stub")
    end
  end

  it "attaches a judge verdict for a rubric'd case and folds it into pass?" do
    t = FakeTransport.new { ok_result }
    judge = FakeJudge.new(pass: false)
    rc = described_class.new(transport: t, judge: judge)
         .run_case(golden("expect" => { "rubric" => "seja cordial" }))
    expect(judge.calls).to eq(1)
    expect(rc.result.judge.pass).to be(false)
    expect(rc.result.pass?).to be(false)      # deterministic ok, but the judge failed it
    expect(rc.result.judge_pending?).to be(false)
  end

  it "does NOT invoke the judge on an errored turn" do
    t = FakeTransport.new { Insika::Evals::TurnResult.new(output_text: "", tool_calls: [], error: "timeout") }
    judge = FakeJudge.new(pass: true)
    rc = described_class.new(transport: t, judge: judge)
         .run_case(golden("expect" => { "rubric" => "x" }))
    expect(judge.calls).to eq(0)
    expect(rc.result.pass?).to be(false)
  end
end
