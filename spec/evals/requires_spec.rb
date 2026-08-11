# frozen_string_literal: true

require "spec_helper"

# `requires` + the third outcome. Deployments differ: some stores have
# order tracking wired, some do not; some run promotions, some do not. A case asserting
# `search_orders` is not a failure for a store without it — it is a case that should
# never have run. Today it would simply fail, and a red suite nobody trusts is worse
# than a small one.
#
# A suite of 40 cases where 12 are SKIPPED says something true. The same 40 with 12
# failures on capability grounds says nothing, and gets ignored.
RSpec.describe "Insika::Evals requires + skipped" do
  # Answers like the deployment does: { "tools" => [...] | nil, "capabilities" => [...] }.
  class FakeCapabilities
    def initialize(map) = @map = map
    def for(agent_id) = @map[agent_id]
  end

  class OneTurnTransport
    attr_reader :calls

    def initialize = @calls = 0

    def turn(agent:, conv:, message:)
      @calls += 1
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: "ok", tool_calls: [], error: nil),
        ttfb: 1.0, total: 2.0
      )
    end
  end

  def golden(requires: nil, expect: {}, agent: "demo-store")
    raw = { "id" => "c", "agent" => agent, "turns" => [{ "user" => "cadê meu pedido?" }], "expect" => expect }
    raw["requires"] = requires if requires
    Insika::Evals::GoldenLoader.build(raw)
  end

  def run(golden, capabilities)
    transport = OneTurnTransport.new
    rc = Insika::Evals::Runner.new(transport: transport, capabilities: capabilities).run_case(golden)
    [rc.result, transport]
  end

  describe "a tool the deployment does not have" do
    let(:capabilities) { FakeCapabilities.new("demo-store" => { "tools" => %w[search_products], "capabilities" => [] }) }

    it "is SKIPPED, never failed" do
      result, = run(golden(requires: { "tools" => ["search_orders"] }), capabilities)

      expect(result).to be_skipped
      expect(result.pass?).to be(false)
      expect(result.skipped).to include("search_orders")
    end

    it "does not spend a turn on it" do
      _result, transport = run(golden(requires: { "tools" => ["search_orders"] }), capabilities)

      expect(transport.calls).to eq(0)
    end

    it "runs when the tool IS there" do
      result, transport = run(golden(requires: { "tools" => ["search_products"] }), capabilities)

      expect(result).not_to be_skipped
      expect(transport.calls).to eq(1)
    end
  end

  describe "a capability the operator did not declare" do
    it "is skipped, and the reason names it" do
      caps = FakeCapabilities.new("demo-store" => { "tools" => [], "capabilities" => %w[human_handoff] })

      result, = run(golden(requires: { "capabilities" => %w[promotions] }), caps)

      expect(result.skipped).to include("capability not declared: promotions")
    end
  end

  describe "an agent with an OPEN tool allowlist (tools: null)" do
    it "runs the case: 'I cannot rule it out' must not become a skip" do
      caps = FakeCapabilities.new("demo-store" => { "tools" => nil, "capabilities" => [] })

      result, transport = run(golden(requires: { "tools" => %w[search_orders] }), caps)

      expect(result).not_to be_skipped
      expect(transport.calls).to eq(1)
    end
  end

  describe "an agent the deployment does not know" do
    it "runs the case rather than shrinking the suite in silence" do
      result, transport = run(golden(requires: { "tools" => %w[search_orders] }), FakeCapabilities.new({}))

      expect(result).not_to be_skipped
      expect(transport.calls).to eq(1)
    end
  end

  describe "a case with no requires" do
    it "never even asks — the existing corpus is untouched" do
      asked = false
      caps = Class.new do
        define_method(:for) { |_id| asked = true }
      end.new

      run(golden, caps)

      expect(asked).to be(false)
    end
  end

  describe "the report" do
    def results(*cases) = cases

    it "counts a skip as neither passed nor failed" do
      skipped = Insika::Evals::Assertions.skip(golden, "tool not available: search_orders")
      passed = Insika::Evals::Assertions.evaluate(
        golden, Insika::Evals::TurnResult.new(output_text: "ok", tool_calls: [], error: nil)
      )

      h = Insika::Evals::Report.to_h([skipped, passed], at: "2026-08-06T00:00:00Z")

      expect(h["total"]).to eq(2)
      expect(h["passed"]).to eq(1)
      expect(h["failed"]).to eq(0)
      expect(h["skipped"]).to eq(1)
    end

    it "prints the REASON — '12 skipped' alone is indistinguishable from a suite that stopped testing" do
      md = Insika::Evals::Report.to_markdown(
        [Insika::Evals::Assertions.skip(golden, "tool not available: search_orders")],
        at: "2026-08-06T00:00:00Z"
      )

      expect(md).to include("skipped: tool not available: search_orders")
      expect(md).to include("1 skipped")
    end

    it "a skipped case awaits no judge" do
      skipped = Insika::Evals::Assertions.skip(golden(expect: { "rubric" => "x" }), "no tool")

      expect(skipped.judge_pending?).to be(false)
    end
  end

  describe "the gate" do
    let(:skipped) { Insika::Evals::Assertions.skip(golden, "tool not available: search_orders") }

    it "leaves a skipped case OUT of the baseline instead of accepting it as failing" do
      snap = Insika::Evals::Baseline.snapshot([skipped], at: "now")

      expect(snap["cases"]).to be_empty
    end

    it "never blocks on a case that was already skipped or unknown" do
      regressions = Insika::Evals::Baseline.compare([skipped], { "cases" => {} }, tolerance: 0.05)

      expect(regressions).to be_empty
    end

    # The one case where a skip DOES speak: it used to run here and no longer can,
    # which means the agent lost a tool or a declaration.
    it "reports pass→skipped, with the reason" do
      base = { "cases" => { "c" => { "pass" => true, "score" => nil } } }

      regressions = Insika::Evals::Baseline.compare([skipped], base, tolerance: 0.05)

      expect(regressions.map(&:kind)).to eq(["pass→skipped"])
      expect(regressions.first.detail).to include("search_orders")
    end
  end

  describe "the case format" do
    it "refuses a `requires` that is not a mapping, at load time" do
      expect do
        Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "a",
                                            "turns" => [{ "user" => "oi" }],
                                            "requires" => %w[search_orders] })
      end.to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /'requires' must be a mapping/)
    end

    it "an absent `requires` reads as 'runs everywhere'" do
      expect(golden.requirements?).to be(false)
    end
  end
end
