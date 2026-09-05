# frozen_string_literal: true

require "spec_helper"

# Evals deterministic assertion engine. Pure over (Golden,
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

  # The call/reply graders — each its own Check, so the report names the one that
  # failed. One pass and one fail per grader.
  describe "the call graders" do
    def calls(*names) = names.map { |n| { "name" => n, "status" => "ok" } }

    it "never_calls: fails naming the tool that was called" do
      pass = described_class.evaluate(golden("never_calls" => ["search_products"]), result(tool_calls: calls("add_to_cart")))
      fail = described_class.evaluate(golden("never_calls" => ["search_products"]), result(tool_calls: calls("search_products")))
      expect(pass.pass?).to be(true)
      expect(fail.failures.map(&:name)).to eq(["never_calls:search_products"])
      expect(fail.failures.first.detail).to eq("called search_products")
    end

    it "calls_one_of: at least one of the listed tools" do
      pass = described_class.evaluate(golden("calls_one_of" => %w[search_products list_categories]), result(tool_calls: calls("list_categories")))
      fail = described_class.evaluate(golden("calls_one_of" => %w[search_products list_categories]), result(tool_calls: calls("add_to_cart")))
      expect(pass.pass?).to be(true)
      expect(fail.failures.map(&:name)).to eq(["calls_one_of"])
      expect(fail.failures.first.detail).to include("saw: add_to_cart")
    end

    it "first_tool: the first call's name" do
      pass = described_class.evaluate(golden("first_tool" => "search_products"), result(tool_calls: calls("search_products", "add_to_cart")))
      fail = described_class.evaluate(golden("first_tool" => "search_products"), result(tool_calls: calls("add_to_cart", "search_products")))
      none = described_class.evaluate(golden("first_tool" => "search_products"), result(tool_calls: []))
      expect(pass.pass?).to be(true)
      expect(fail.failures.first.detail).to eq("first call was add_to_cart")
      expect(none.failures.first.detail).to eq("first call was none")
    end

    it "max_tool_calls: a ceiling on the turn's calls" do
      pass = described_class.evaluate(golden("max_tool_calls" => 2), result(tool_calls: calls("a", "b")))
      fail = described_class.evaluate(golden("max_tool_calls" => 1), result(tool_calls: calls("a", "b")))
      expect(pass.pass?).to be(true)
      expect(fail.failures.map(&:name)).to eq(["max_tool_calls:1"])
      expect(fail.failures.first.detail).to eq("2 call(s): a, b")
    end

    it "blocked_gates: each tool:gate pair appears among the BLOCKED calls" do
      blocked = [{ "name" => "add_to_cart", "status" => "blocked", "gate" => "provenance" }]
      pass = described_class.evaluate(golden("blocked_gates" => ["add_to_cart:provenance"]), result(tool_calls: blocked))
      ran = described_class.evaluate(golden("blocked_gates" => ["add_to_cart:provenance"]), result(tool_calls: calls("add_to_cart")))
      other = described_class.evaluate(golden("blocked_gates" => ["add_to_cart:provenance"]),
                                       result(tool_calls: [{ "name" => "add_to_cart", "status" => "blocked", "gate" => "budget" }]))
      expect(pass.pass?).to be(true)
      expect(ran.failures.first.detail).to eq("not held (blocked: none)")
      expect(other.failures.first.detail).to eq("not held (blocked: add_to_cart:budget)")
    end

    it "a BLOCKED call is not a tool_error (the tool never ran)" do
      blocked = [{ "name" => "add_to_cart", "status" => "blocked", "gate" => "provenance" }]
      r = described_class.evaluate(golden("must_not" => ["tool_error"]), result(tool_calls: blocked))
      expect(r.pass?).to be(true)
      expect(result(tool_calls: blocked).blocked_tools).to eq(blocked)
    end
  end

  describe "the reply graders (case-insensitive substrings over the published answer)" do
    it "reply_includes / reply_omits, each naming the substring" do
      text = "O frete para 01311-000 sai por R$ 20."
      pass = described_class.evaluate(golden("reply_includes" => ["FRETE"], "reply_omits" => ["SKU-1"]), result(output_text: text))
      fail = described_class.evaluate(golden("reply_includes" => ["cupom"], "reply_omits" => ["01311-000"]), result(output_text: text))
      expect(pass.pass?).to be(true)
      expect(fail.failures.map(&:name)).to eq(["reply_includes:cupom", "reply_omits:01311-000"])
      expect(fail.failures.map(&:detail)).to eq(["missing from the reply", "present in the reply"])
    end

    it "the report names the grader that failed" do
      r = described_class.evaluate(golden("tools_called" => ["add_to_cart"], "never_calls" => ["search_products"], "reply_omits" => ["SKU-1"]),
                                   result(output_text: "adicionei o SKU-1", tool_calls: [{ "name" => "add_to_cart" }, { "name" => "search_products" }]))
      md = Insika::Evals::Report.to_markdown([r], at: "2026-01-01T00:00:00Z")
      expect(md).to include("❌ never_calls:search_products: called search_products")
      expect(md).to include("❌ reply_omits:SKU-1: present in the reply")
      expect(md).not_to include("tool:add_to_cart")
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
      .to raise_error(ArgumentError, /unknown detector/) # runtime is the single source
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
