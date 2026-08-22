# frozen_string_literal: true

require "spec_helper"

# Pairwise against the incumbent. Pure over injected `asks`, so the
# whole protocol — anonymity, both orders, the panel tally — is testable with no LLM.
RSpec.describe Insika::Evals::Pairwise do
  # A judge that answers by ORDER of the calls it receives. Records every prompt.
  def scripted(*answers)
    seen = []
    ask = lambda do |prompt|
      seen << prompt
      answers[seen.length - 1] || answers.last
    end
    [ask, seen]
  end

  def json(winner, reason = "because") = %({"winner": "#{winner}", "reason": "#{reason}"})

  def golden(reference_messages, id: "c")
    Insika::Evals::GoldenLoader.build(
      { "id" => id, "agent" => "bia", "turns" => [{ "user" => "tem creatina?" }],
        "expect" => {}, "reference" => { "source" => "chat 42", "messages" => reference_messages } }
    )
  end

  def turns(*texts)
    texts.map { |t| Insika::Evals::TurnResult.new(output_text: t, tool_calls: [], error: nil) }
  end

  let(:reference) do
    [{ "role" => "user", "text" => "tem creatina?" },
     { "role" => "assistant", "text" => "temos sim, segue o link" }]
  end

  it "returns nil for a case with no reference — most of the corpus" do
    plain = Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "bia",
                                                "turns" => [{ "user" => "oi" }], "expect" => {} })
    ask, seen = scripted(json("A"))
    expect(described_class.new(asks: [ask]).compare(golden: plain, turns: turns("oi!"))).to be_nil
    expect(seen).to be_empty # and it costs nothing
  end

  # The two rules that make the verdict worth quoting.
  describe "the protocol" do
    it "asks TWICE with the sides swapped and never names Insika" do
      ask, seen = scripted(json("A"), json("B"))
      described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))

      expect(seen.length).to eq(2)
      expect(seen).to all(satisfy { |p| !p.include?("Insika") })
      # order 1: ours is A; order 2: ours is B
      expect(seen[0].index("temos!")).to be < seen[0].index("segue o link")
      expect(seen[1].index("temos!")).to be > seen[1].index("segue o link")
    end

    # "A won" and then "B won" is the SAME preference (we swapped). Reading it as a
    # disagreement would make every consistent judge look unstable.
    it "maps the swapped answer back, so a consistent judge reads as one verdict" do
      ask, = scripted(json("A"), json("B"))
      v = described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.outcome).to eq("better")
      expect(v.order_dependent).to be(false)
    end

    it "reports a preference that FLIPS with presentation order as comparable" do
      # "A" both times = the judge just likes whatever is printed first.
      ask, = scripted(json("A"), json("A"))
      v = described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.outcome).to eq("comparable")
      expect(v.order_dependent).to be(true)
    end

    it "reads a tie as comparable" do
      ask, = scripted(json("tie"), json("tie"))
      v = described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.outcome).to eq("comparable")
      expect(v.order_dependent).to be(false)
    end
  end

  describe "the panel" do
    def panel_of(*per_judge_answers)
      asks = per_judge_answers.map { |answers| scripted(*answers).first }
      described_class.new(asks: asks).compare(golden: golden(reference), turns: turns("temos!"))
    end

    it "takes a strict majority" do
      v = panel_of([json("A"), json("B")], [json("A"), json("B")], [json("B"), json("A")])
      expect(v.outcome).to eq("better")
      expect(v.judges).to eq(%w[better better worse])
    end

    # a split panel is reported as split, never averaged into a fake
    # verdict — "better" and "worse" do not average to "comparable".
    it "reports a tied panel as split instead of inventing agreement" do
      v = panel_of([json("A"), json("B")], [json("B"), json("A")])
      expect(v.outcome).to eq("split")
      expect(v.judges).to eq(%w[better worse])
    end
  end

  describe "when a judge does not answer" do
    it "is UNKNOWN, never a tie — a broken judge is not evidence of equivalence" do
      ask, = scripted("desculpa, não entendi", "tampouco")
      v = described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.outcome).to eq("unknown")
      expect(v.reason).to include("unparseable")
    end

    it "leaves the unreadable judge out of the tally but keeps it visible" do
      asks = [scripted("prosa", "prosa").first,
              scripted(json("A"), json("B")).first]
      v = described_class.new(asks: asks).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.outcome).to eq("better")
      expect(v.judges).to eq(%w[unknown better])
    end
  end

  describe "who the reference half actually is" do
    it "labels a pair whose reference a PERSON typed" do
      human = reference + [{ "role" => "assistant", "text" => "aqui é a Ana, segue", "origin" => "operator" }]
      ask, seen = scripted(json("A"), json("B"))
      v = described_class.new(asks: [ask]).compare(golden: golden(human), turns: turns("temos!"))

      expect(v.vs).to eq("human-assisted")
      expect(v.human_assisted?).to be(true)
      # …and the judge is NOT told: it grades the conversation as the customer got it.
      expect(seen).to all(satisfy { |p| !p.include?("operator") })
    end

    it "labels a model-vs-model pair `agent`" do
      ask, = scripted(json("A"), json("B"))
      v = described_class.new(asks: [ask]).compare(golden: golden(reference), turns: turns("temos!"))
      expect(v.vs).to eq("agent")
    end
  end

  it "builds our half from the turns that actually ran" do
    g = Insika::Evals::GoldenLoader.build(
      { "id" => "c", "agent" => "bia",
        "turns" => [{ "user" => "oi" }, { "user" => "tem creatina?" }], "expect" => {},
        "reference" => { "messages" => reference } }
    )
    ask, seen = scripted(json("A"), json("B"))
    described_class.new(asks: [ask]).compare(golden: g, turns: turns("olá!", "temos!"))

    expect(seen[0]).to include("customer: oi\nassistant: olá!\ncustomer: tem creatina?\nassistant: temos!")
  end

  # the shadow pairs are graded by the SAME object with the SAME
  # prompt — two transcripts, no golden.
  describe "compare_texts (the shadow seam)" do
    let(:ours) { "customer: tem creatina?\nassistant: temos, segue o link" }
    let(:theirs) { "customer: tem creatina?\nassistant: acho que sim" }

    it "produces the identical verdict compare() would for the same two transcripts" do
      via_compare = described_class.new(asks: [scripted(json("A"), json("B")).first])
                                  .compare(golden: golden(reference), turns: turns("temos, segue o link"))
      via_texts = described_class.new(asks: [scripted(json("A"), json("B")).first])
                                 .compare_texts(ours: ours, theirs: theirs)

      expect(via_texts.to_h).to eq(via_compare.to_h)
    end

    it "labels the incumbent a human-assisted half when asked" do
      ask, = scripted(json("A"), json("B"))
      v = described_class.new(asks: [ask]).compare_texts(ours: ours, theirs: theirs, vs: "human-assisted")
      expect(v.vs).to eq("human-assisted")
      expect(v.human_assisted?).to be(true)
    end

    it "returns nil when either side is empty — never judges against an empty string" do
      ask, seen = scripted(json("A"), json("B"))
      expect(described_class.new(asks: [ask]).compare_texts(ours: "", theirs: theirs)).to be_nil
      expect(described_class.new(asks: [ask]).compare_texts(ours: ours, theirs: "  ")).to be_nil
      expect(seen).to be_empty
    end
  end

  # an empty REFERENCE transcript is now refused instead of
  # judged against an empty string (a fix, called out so it is not discovered).
  it "returns nil for an empty reference transcript" do
    empty = Struct.new(:reference?, :user_turns, :reference_messages, :human_assisted?)
            .new(true, ["tem creatina?"], [{ "role" => "assistant", "text" => "  " }], false)
    ask, seen = scripted(json("A"), json("B"))
    expect(described_class.new(asks: [ask]).compare(golden: empty, turns: turns("temos!"))).to be_nil
    expect(seen).to be_empty
  end

  # A GENERATED (simulated) transcript maps to the same
  # customer/assistant lines a replay produces, so a simulated run can be compared
  # against the incumbent like for like.
  describe ".transcript_text" do
    it "renders a simulated transcript as interleaved customer/assistant lines" do
      text = described_class.transcript_text(
        [{ role: "user", text: "oi, queria um presente" },
         { role: "assistant", text: "pra quem é?" },
         { role: "user", text: "minha mãe" }]
      )
      expect(text).to eq("customer: oi, queria um presente\nassistant: pra quem é?\ncustomer: minha mãe")
    end
  end
end
