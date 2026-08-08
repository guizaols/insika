# frozen_string_literal: true

require "spec_helper"

# The `reference:` half of a pair (RFC-0014 §3.4), from the file to the report. The
# comparison itself is `pairwise_spec.rb`; this is the plumbing that has to keep the
# incumbent's transcript intact — a case that silently loses its reference stops being
# compared and the report looks exactly the same.
RSpec.describe "Insika::Evals reference" do
  class RefTransport
    def turn(agent:, conv:, message:)
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: "temos creatina sim", tool_calls: [], error: nil),
        ttfb: 1.0, total: 2.0
      )
    end
  end

  class FailingTransport
    def turn(agent:, conv:, message:)
      Insika::Evals::TurnOutcome.new(
        result: Insika::Evals::TurnResult.new(output_text: "", tool_calls: [], error: "boom"),
        ttfb: 1.0, total: 2.0
      )
    end
  end

  # Always answers "the first one printed wins", which after the swap reads as
  # order-dependent — the cheapest honest fake.
  def constant_judge(winner) = ->(_prompt) { %({"winner": "#{winner}", "reason": "r"}) }

  # Prefers whichever transcript contains `marker`, in either position.
  def preferring(marker)
    lambda do |prompt|
      a = prompt[/CONVERSATION A:\n(.*?)\n\nCONVERSATION B:/m, 1].to_s
      %({"winner": "#{a.include?(marker) ? 'A' : 'B'}", "reason": "r"})
    end
  end

  def build(raw) = Insika::Evals::GoldenLoader.build(raw)

  def case_raw(reference)
    { "id" => "consulta", "agent" => "ocean-drop", "turns" => [{ "user" => "tem creatina?" }],
      "expect" => {}, "reference" => reference }
  end

  let(:messages) do
    [{ "role" => "user", "text" => "tem creatina?" },
     { "role" => "assistant", "text" => "temos! segue o link" }]
  end

  describe "loading" do
    it "reads source + messages and reports the case as comparable" do
      g = build(case_raw("source" => "achei-b2b chat 42", "messages" => messages))
      expect(g.reference?).to be(true)
      expect(g.reference_source).to eq("achei-b2b chat 42")
      expect(g.reference_messages.length).to eq(2)
      expect(g.human_assisted?).to be(false)
    end

    it "leaves a case with no reference exactly as it was" do
      g = build("id" => "c", "agent" => "bia", "turns" => [{ "user" => "oi" }], "expect" => {})
      expect(g.reference).to eq({})
      expect(g.reference?).to be(false)
    end

    it "marks a reference a human typed" do
      human = messages + [{ "role" => "assistant", "text" => "aqui é a Ana", "origin" => "operator" }]
      expect(build(case_raw("messages" => human)).human_assisted?).to be(true)
    end

    # A reference that half-loads would produce a verdict about a transcript nobody
    # wrote, so every shape error is refused at load time.
    it "refuses a reference with no messages" do
      expect { build(case_raw("source" => "chat 42")) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /non-empty 'messages'/)
    end

    it "refuses a message with no text" do
      expect { build(case_raw("messages" => [{ "role" => "user" }])) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /non-empty 'text'/)
    end

    it "refuses a role that is neither side of the conversation" do
      expect { build(case_raw("messages" => [{ "role" => "system", "text" => "x" }])) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /user or assistant/)
    end

    # The same closed vocabulary the engine stamps (P23a): a typo'd marker reads as
    # "absent" downstream, which is how a human turn gets scored as the incumbent's.
    it "refuses an unknown origin instead of storing it" do
      expect { build(case_raw("messages" => [{ "role" => "assistant", "text" => "x", "origin" => "humano" }])) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /unknown message origin/)
    end
  end

  describe "the runner" do
    def run(golden, pairwise: nil, transport: RefTransport.new)
      Insika::Evals::Runner.new(transport: transport, pairwise: pairwise).run_case(golden).result
    end

    it "attaches the verdict when a panel is configured" do
      pw = Insika::Evals::Pairwise.new(asks: [preferring("temos creatina sim")])
      result = run(build(case_raw("messages" => messages)), pairwise: pw)
      expect(result.pairwise.outcome).to eq("better")
    end

    it "does not compare when no panel is configured" do
      expect(run(build(case_raw("messages" => messages))).pairwise).to be_nil
    end

    # "Worse than the incumbent" is an answer to "can we replace it", not a regression
    # in the suite. Letting it fail a case would put an opinion about two conversations
    # into the pre-merge gate.
    it "never changes pass/fail" do
      pw = Insika::Evals::Pairwise.new(asks: [preferring("segue o link")])
      result = run(build(case_raw("messages" => messages)), pairwise: pw)
      expect(result.pairwise.outcome).to eq("worse")
      expect(result.pass?).to be(true)
    end

    it "skips the comparison on a turn that errored — half a conversation is not a loss" do
      pw = Insika::Evals::Pairwise.new(asks: [constant_judge("A")])
      result = run(build(case_raw("messages" => messages)), pairwise: pw, transport: FailingTransport.new)
      expect(result.pairwise).to be_nil
    end
  end

  describe "the report" do
    def result_with(verdict)
      Insika::Evals::CaseResult.new(id: "consulta", agent: "ocean-drop", checks: [], error: nil,
                                    rubric: nil, judge: nil, skipped: nil, pairwise: verdict)
    end

    def verdict(outcome, vs: "agent", order_dependent: false)
      Insika::Evals::Pairwise::Verdict.new(outcome: outcome, vs: vs, reason: "r",
                                           judges: [outcome], order_dependent: order_dependent)
    end

    it "has no pairwise block at all when nothing was compared" do
      h = Insika::Evals::Report.to_h([result_with(nil)], at: "now")
      expect(h).not_to have_key("pairwise")
      expect(h["cases"].first["pairwise"]).to be_nil
    end

    it "counts the outcomes" do
      h = Insika::Evals::Report.to_h([result_with(verdict("better")), result_with(verdict("worse"))], at: "now")
      expect(h["pairwise"]["compared"]).to eq(2)
      expect(h["pairwise"]["outcomes"]).to eq("better" => 1, "worse" => 1)
    end

    # A "better" against a conversation a PERSON typed is a different claim, and the
    # two must never be summed into one number somebody quotes.
    it "always prints who the reference half was" do
      md = Insika::Evals::Report.to_markdown(
        [result_with(verdict("better", vs: "human-assisted"))], at: "now"
      )
      expect(md).to include("vs incumbent (human-assisted): better")
      expect(md).to include("1 against a HUMAN-ASSISTED transcript")
    end

    it "says when a verdict flipped with presentation order" do
      md = Insika::Evals::Report.to_markdown(
        [result_with(verdict("comparable", order_dependent: true))], at: "now"
      )
      expect(md).to include("comparable (order-dependent)")
      expect(md).to include("1 flipped when the transcripts were swapped")
    end
  end

  describe "the store" do
    it "round-trips the reference through a write and a read" do
      store = Insika::GoldenStore.new(config_store: Insika::ConfigStore.new(store: Insika::Stores::Memory.new))
      store.write(case_raw("source" => "chat 42", "messages" => messages))
      expect(store.find("consulta").reference_messages).to eq(messages)
    end
  end
end
