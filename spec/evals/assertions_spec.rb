# frozen_string_literal: true

require "spec_helper"

# Evals deterministic assertion engine (RFC-0008, Fase A). Pure over (Golden,
# TurnResult) — no server, no tokens.
RSpec.describe Insika::Evals::Assertions do
  def golden(expect)
    Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia", "turns" => [{ "user" => "oi" }], "expect" => expect })
  end

  def result(output_text: "ok", tool_calls: [], error: nil)
    Insika::Evals::TurnResult.new(output_text: output_text, tool_calls: tool_calls, error: error)
  end

  describe "tools_called" do
    it "passes when a required tool was called" do
      r = described_class.evaluate(golden("tools_called" => ["shipping_quote"]),
                                   result(tool_calls: [{ "name" => "shipping_quote", "status" => "ok" }]))
      expect(r.pass?).to be(true)
    end

    it "fails when a required tool is missing (and lists what it saw)" do
      r = described_class.evaluate(golden("tools_called" => ["shipping_quote"]),
                                   result(tool_calls: [{ "name" => "search_products" }]))
      expect(r.pass?).to be(false)
      expect(r.failures.first.detail).to include("search_products")
    end

    it "never fails on an OPTIONAL tool that wasn't called" do
      r = described_class.evaluate(golden("tools_called" => ["search_products?"]), result(tool_calls: []))
      expect(r.checks).to be_empty
      expect(r.pass?).to be(true)
    end
  end

  describe "must_not: pii_leak" do
    it "flags a formatted CPF in the output" do
      r = described_class.evaluate(golden("must_not" => ["pii_leak"]),
                                   result(output_text: "seu CPF 123.456.789-09 consta"))
      expect(r.pass?).to be(false)
    end

    it "flags a leaked credential" do
      r = described_class.evaluate(golden("must_not" => ["pii_leak"]),
                                   result(output_text: "use Bearer sk-abcdef0123456789ABCDEF"))
      expect(r.pass?).to be(false)
    end

    it "passes on clean text (an order number is not a CPF)" do
      r = described_class.evaluate(golden("must_not" => ["pii_leak"]),
                                   result(output_text: "seu pedido 123456789 saiu para entrega"))
      expect(r.pass?).to be(true)
    end
  end

  describe "must_not: tool_error" do
    it "fails when a tool returned a non-2xx status" do
      r = described_class.evaluate(golden("must_not" => ["tool_error"]),
                                   result(tool_calls: [{ "name" => "shipping_quote", "status" => 500 }]))
      expect(r.pass?).to be(false)
    end

    it "passes when every tool status is ok/2xx/blank" do
      r = described_class.evaluate(golden("must_not" => ["tool_error"]),
                                   result(tool_calls: [{ "name" => "a", "status" => "ok" },
                                                       { "name" => "b", "status" => 200 },
                                                       { "name" => "c" }]))
      expect(r.pass?).to be(true)
    end
  end

  it "turns a transport/turn error into a single failing check" do
    r = described_class.evaluate(golden("tools_called" => ["x"]), result(error: "timeout"))
    expect(r.pass?).to be(false)
    expect(r.error).to eq("timeout")
    expect(r.checks.map(&:name)).to eq(["turn"])
  end

  it "marks a case with a rubric as judge_pending? until a verdict is attached" do
    r = described_class.evaluate(golden("rubric" => "seja cordial"), result)
    expect(r.judge_pending?).to be(true)
    expect(r.pass?).to be(true) # deterministic checks pass; judge is separate
  end

  it "raises on an unknown must_not detector (a typo must not pass silently)" do
    expect { described_class.evaluate(golden("must_not" => ["nope"]), result) }
      .to raise_error(ArgumentError, /unknown detector/) # runtime is the single source (D4)
  end

  describe Insika::Evals::Report do
    it "aggregates pass/fail/judge_pending counts" do
      results = [
        Insika::Evals::Assertions.evaluate(golden("tools_called" => ["a"]), result(tool_calls: [{ "name" => "a" }])),
        Insika::Evals::Assertions.evaluate(golden("tools_called" => ["b"]), result(tool_calls: [])),
        Insika::Evals::Assertions.evaluate(golden("rubric" => "x"), result)
      ]
      h = Insika::Evals::Report.to_h(results, at: "2026-07-19T00:00:00Z")
      expect(h["total"]).to eq(3)
      expect(h["passed"]).to eq(2)
      expect(h["failed"]).to eq(1)
      expect(h["judge_pending"]).to eq(1)
      expect(Insika::Evals::Report.to_markdown(results, at: "2026-07-19T00:00:00Z")).to include("2/3 passed")
    end
  end
end
