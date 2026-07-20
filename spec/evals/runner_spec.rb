# frozen_string_literal: true

require "spec_helper"
require_relative "../../evals/lib/evals/golden"
require_relative "../../evals/lib/evals/runner"

# Runner orchestration (RFC-0008). Pure over the Transport — a fake makes the
# replay/evaluate loop testable offline, no server or LLM.
RSpec.describe Evals::Runner do
  # Returns a scripted TurnResult per message; records the messages it saw.
  class FakeTransport
    attr_reader :seen

    def initialize(&script)
      @script = script
      @seen = []
    end

    def turn(agent:, conv:, message:)
      @seen << { agent: agent, conv: conv, message: message }
      Evals::TurnOutcome.new(result: @script.call(message), ttfb: 1.0, total: 2.0)
    end
  end

  def golden(overrides = {})
    Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia",
                                "turns" => [{ "user" => "oi" }], "expect" => {} }.merge(overrides))
  end

  def ok_result(tools = [])
    Evals::TurnResult.new(output_text: "ok", tool_calls: tools, error: nil)
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

  it "aborts the conversation on a turn error and fails the case" do
    g = golden("turns" => [{ "user" => "a" }, { "user" => "b" }])
    t = FakeTransport.new { Evals::TurnResult.new(output_text: "", tool_calls: [], error: "timeout") }
    rc = described_class.new(transport: t).run_case(g)
    expect(rc.result.pass?).to be(false)
    expect(rc.result.error).to eq("timeout")
    expect(t.seen.size).to eq(1) # never sent the 2nd turn
  end

  it "runs a whole set" do
    t = FakeTransport.new { ok_result }
    results = described_class.new(transport: t).run([golden, golden("id" => "c2")])
    expect(results.size).to eq(2)
    expect(results).to all(be_a(Evals::Runner::RunCase))
  end
end
