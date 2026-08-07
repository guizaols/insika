# frozen_string_literal: true

require "spec_helper"

# Runner orchestration (RFC-0008). Pure over the Transport — a fake makes the
# replay/evaluate loop testable offline, no server or LLM.
RSpec.describe Insika::Evals::Runner do
  # Returns a scripted TurnResult per message; records the messages it saw.
  class FakeTransport
    attr_reader :seen

    # usage: a per-turn hash (or nil), like the deployment reports on
    # `response.completed`. Only RFC-0013's budget reads it.
    def initialize(usage: nil, &script)
      @script = script
      @usage = usage
      @seen = []
    end

    def turn(agent:, conv:, message:)
      @seen << { agent: agent, conv: conv, message: message }
      Insika::Evals::TurnOutcome.new(result: @script.call(message), ttfb: 1.0, total: 2.0,
                                     usage: @usage.respond_to?(:call) ? @usage.call(message) : @usage)
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

  # RFC-0013 §3.9: the refinement gate has to bound what a replay costs, and it can
  # only do that if the case carries what its turns actually spent. Nothing else
  # reads this — the report and the exit code are untouched.
  describe "what a case cost" do
    let(:multi) { golden("turns" => [{ "user" => "oi" }, { "user" => "e o frete?" }]) }

    it "sums the turns the deployment metered" do
      t = FakeTransport.new(usage: { "total_tokens" => 400 }) { ok_result }
      expect(described_class.new(transport: t).run_case(multi).tokens).to eq(800)
    end

    # `total_tokens` is input + output and EXCLUDES the cached prefix (see
    # `Executor#usage_of`), so reading it as the cost of a turn under-reads a cached
    # identity by an order of magnitude. Measured on the pilot: 88 total against
    # 26_624 cached, on a 27k-token pack.
    it "bills the prompt cache too, and carries it separately" do
      t = FakeTransport.new(usage: { "total_tokens" => 88, "cached_tokens" => 26_624,
                                     "cache_creation_tokens" => 100 }) { ok_result }
      rc = described_class.new(transport: t).run_case(multi)

      expect(rc.tokens).to eq((88 + 26_624 + 100) * 2)
      expect(rc.cached).to eq((26_624 + 100) * 2)
    end

    it "reports no cache when the provider mentions none" do
      t = FakeTransport.new(usage: { "total_tokens" => 400 }) { ok_result }
      expect(described_class.new(transport: t).run_case(multi).cached).to be_nil
    end

    # "The provider did not say" and "it cost nothing" are different facts, and a
    # budget that confuses them stops being a budget.
    it "is nil when no turn reported usage" do
      t = FakeTransport.new { ok_result }
      expect(described_class.new(transport: t).run_case(multi).tokens).to be_nil
    end

    # Low rather than absent: a budget under-counting is a smaller lie than one that
    # throws the number away because a single leg was silent.
    it "reports what was measured when only some turns were metered" do
      t = FakeTransport.new(usage: ->(m) { m.include?("frete") ? { "total_tokens" => 400 } : nil }) { ok_result }
      expect(described_class.new(transport: t).run_case(multi).tokens).to eq(400)
    end

    it "is nil for a skipped case, which spent nothing" do
      skipped = golden("requires" => { "tools" => ["search_orders"] })
      caps = Struct.new(:answer) { def for(_a) = answer }.new({ "tools" => [], "capabilities" => [] })
      rc = described_class.new(transport: FakeTransport.new { ok_result }, capabilities: caps).run_case(skipped)
      expect(rc.result).to be_skipped
      expect(rc.tokens).to be_nil
    end
  end
end
