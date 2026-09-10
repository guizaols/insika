# frozen_string_literal: true

require "spec_helper"

# Runner orchestration. Pure over the Transport — a fake makes the
# replay/evaluate loop testable offline, no server or LLM.
RSpec.describe Insika::Evals::Runner do
  # Returns a scripted TurnResult per message; records the messages it saw.
  class FakeTransport
    attr_reader :seen

    # usage: a per-turn hash (or nil), like the deployment reports on
    # `response.completed`. Only's budget reads it.
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

  # `state:` — the snapshot goes into the conversation BEFORE turn 1, on the same
  # conv id the turns continue. A transport that cannot seed skips the case with
  # the reason (never a silent pass against an empty state).
  describe "a seeded case" do
    class SeedingFakeTransport < FakeTransport
      attr_reader :seeds

      def initialize(refuse: nil, &script)
        super(&script)
        @seeds = []
        @refuse = refuse
      end

      def seed(conv, state, customer: nil)
        @seeds << { conv: conv, state: state, customer: customer, before_turns: seen.size }
        raise @refuse if @refuse
      end
    end

    let(:state) { { "evidence" => { "ids" => ["SKU-1"] } } }
    let(:seeded) { golden("state" => state, "expect" => { "tools_called" => ["add_to_cart"] }) }

    it "seeds the conversation with the case's state before turn 1" do
      t = SeedingFakeTransport.new { ok_result([{ "name" => "add_to_cart" }]) }
      rc = described_class.new(transport: t).run_case(seeded)

      expect(rc.result.pass?).to be(true)
      expect(t.seeds).to eq([{ conv: "eval-c", state: state, customer: nil, before_turns: 0 }])
      expect(t.seen.first[:conv]).to eq("eval-c")
    end

    it "an unseeded case never calls seed" do
      t = SeedingFakeTransport.new { ok_result }
      described_class.new(transport: t).run_case(golden)
      expect(t.seeds).to be_empty
    end

    it "a transport without #seed -> SKIPPED with the reason, no turn spent" do
      t = FakeTransport.new { ok_result }
      rc = described_class.new(transport: t).run_case(seeded)

      expect(rc.result.skipped?).to be(true)
      expect(rc.result.skipped).to eq("transport cannot seed state")
      expect(rc.result.pass?).to be(false)
      expect(t.seen).to be_empty
    end

    it "a deployment that refuses seeding (403) -> SKIPPED with the reason, never a false pass" do
      t = SeedingFakeTransport.new(refuse: Insika::Evals::SeedRefused.new("HTTP 403 seeding is off")) { ok_result }
      rc = described_class.new(transport: t).run_case(seeded)

      expect(rc.result.skipped).to eq("deployment refuses seeding — HTTP 403 seeding is off")
      expect(t.seen).to be_empty
    end

    it "a seed that FAILS (409, network) fails the case as a turn error" do
      t = SeedingFakeTransport.new(refuse: Insika::Error.new("HTTP 409 already has 2 message(s)")) { ok_result }
      rc = described_class.new(transport: t).run_case(seeded)

      expect(rc.result.skipped?).to be(false)
      expect(rc.result.pass?).to be(false)
      expect(rc.result.error).to eq("seed failed: HTTP 409 already has 2 message(s)")
      expect(t.seen).to be_empty
    end
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

  # A simulated case (persona) cannot be REPLAYED — the turns do not exist until a
  # Simulator generates them. The replay Runner must skip it loudly, never run it
  # as an empty script (which would silently read as a pass).
  describe "simulated (persona) cases" do
    it "skips a persona case with the reason instead of replaying nothing" do
      sim = Insika::Evals::GoldenLoader.build({
        "id" => "c-sim", "agent" => "bia",
        "persona" => { "goal" => "g", "knows" => { "a" => "b" },
                       "opens_with" => "oi", "max_turns" => 4 },
        "expect" => {}
      })
      t = FakeTransport.new { ok_result }
      rc = described_class.new(transport: t).run_case(sim)
      expect(rc.result).to be_skipped
      expect(rc.result.skipped).to include("simulated")
      expect(t.seen).to be_empty
      expect(rc.tokens).to be_nil
    end
  end

  # the refinement gate has to bound what a replay costs, and it can
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


# The bench half of the Runner: a store to grade against, and a transport that
# cannot see tool calls.
RSpec.describe Insika::Evals::Runner do
  class BenchFakeTransport
    def initialize(reports_tool_calls: true, &script)
      @script = script
      @reports = reports_tool_calls
    end

    def reports_tool_calls? = @reports

    def turn(agent:, conv:, message:)
      Insika::Evals::TurnOutcome.new(result: @script.call(message), ttfb: nil, total: 1.0, usage: nil)
    end
  end

  # Answers rows per collection; raises when built with one.
  class FakeStoreReader
    attr_reader :asked

    def initialize(rows = {}, raising: nil)
      @rows = rows
      @raising = raising
      @asked = []
    end

    def read(collection)
      @asked << collection
      raise Insika::Error, @raising if @raising

      @rows[collection.to_s] || []
    end
  end

  def bench_golden(store_state, expect = {})
    Insika::Evals::GoldenLoader.build({ "id" => "bench", "agent" => "bia", "turns" => [{ "user" => "compra" }],
                                        "expect" => expect, "store_state" => store_state })
  end

  def answered(text = "pronto", tools = [])
    Insika::Evals::TurnResult.new(output_text: text, tool_calls: tools, error: nil)
  end

  it "grades the store after the turn, asking only for the collections the case names" do
    reader = FakeStoreReader.new({ "orders" => [{ "total" => 189.9 }] })
    rc = described_class.new(transport: BenchFakeTransport.new { answered }, store_reader: reader)
                        .run_case(bench_golden({ "count" => { "orders" => 1 } }))
    expect(rc.result.pass?).to be(true)
    expect(reader.asked).to eq(["orders"])
  end

  # The claim the bench exists to make: a confident reply over a store that never
  # changed is a failure, not a pass.
  it "a confident answer with no order fails" do
    reader = FakeStoreReader.new({ "orders" => [] })
    rc = described_class.new(transport: BenchFakeTransport.new { answered("pedido confirmado!") },
                             store_reader: reader)
                        .run_case(bench_golden({ "count" => { "orders" => 1 } }))
    expect(rc.result.pass?).to be(false)
    expect(rc.result.failures.first.detail).to eq("expected 1, saw 0")
  end

  it "a case that needs a store with no reader configured is skipped, never run and passed" do
    rc = described_class.new(transport: BenchFakeTransport.new { answered })
                        .run_case(bench_golden({ "count" => { "orders" => 1 } }))
    expect(rc.result).to be_skipped
    expect(rc.result.skipped).to include("no store reader")
  end

  it "a reader that raises fails the case with the reason instead of killing the run" do
    reader = FakeStoreReader.new(raising: "no store snapshot on disk")
    rc = described_class.new(transport: BenchFakeTransport.new { answered }, store_reader: reader)
                        .run_case(bench_golden({ "count" => { "orders" => 1 } }))
    expect(rc.result.pass?).to be(false)
    expect(rc.result.failures.first.detail).to include("no store snapshot on disk")
  end

  it "a transport that reports no tool calls skips the tool graders and grades the rest" do
    transport = BenchFakeTransport.new(reports_tool_calls: false) { answered("pedido feito") }
    g = Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia", "turns" => [{ "user" => "compra" }],
                                            "expect" => { "tools_called" => ["create_order"],
                                                          "reply_includes" => ["pedido"] } })
    rc = described_class.new(transport: transport).run_case(g)
    expect(rc.result.pass?).to be(true)
    expect(rc.result.skipped_checks.map(&:name)).to eq(["tool:create_order"])
  end

  # What the case SAW, carried out of the runner: a verdict alone cannot be argued
  # with, and the reply behind a cell that passed is where the next task comes from.
  it "carries every turn and the store it left behind" do
    reader = FakeStoreReader.new({ "orders" => [{ "total" => 10 }] })
    transport = BenchFakeTransport.new { |m| answered("resposta a #{m}", [{ "name" => "search_products" }]) }
    g = Insika::Evals::GoldenLoader.build({ "id" => "two", "agent" => "bia",
                                            "turns" => [{ "user" => "oi" }, { "user" => "e o frete?" }],
                                            "expect" => {}, "store_state" => { "count" => { "orders" => 1 } } })

    rc = described_class.new(transport: transport, store_reader: reader).run_case(g)

    expect(rc.turns.map(&:output_text)).to eq(["resposta a oi", "resposta a e o frete?"])
    expect(rc.turns.first.tool_names).to eq(["search_products"])
    expect(rc.store).to eq({ "orders" => [{ "total" => 10 }] })
  end
end
